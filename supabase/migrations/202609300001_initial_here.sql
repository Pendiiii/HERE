-- HERE production MVP schema. Raw geography never leaves SECURITY DEFINER functions.
create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create type public.post_category as enum ('general','question','food','ride','activity','free','warning','campus','event');
create type public.report_target as enum ('post','reply');
create type public.report_status as enum ('pending','queued','resolved','dismissed');
create type public.sanction_kind as enum ('mute','ban');

create table public.profiles (
  id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 3 and 24),
  created_at timestamptz not null default now()
);

create table public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 280),
  category public.post_category,
  location extensions.geography(point, 4326) not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  deleted_at timestamptz,
  constraint valid_post_lifetime check (expires_at > created_at and expires_at <= created_at + interval '6 hours')
);

create table public.replies (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 280),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  target_type public.report_target not null,
  target_id uuid not null,
  reason text not null check (reason in ('Spam','Belästigung','Hass','Sexuelle Inhalte','Gefährliches Verhalten','Betrug','Persönliche Informationen','Sonstiges')),
  created_at timestamptz not null default now(),
  status public.report_status not null default 'pending',
  discord_message_id text,
  reviewed_by text,
  reviewed_at timestamptz,
  resolution text,
  unique (reporter_id, target_type, target_id)
);

create table public.sanctions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind public.sanction_kind not null,
  reason text not null,
  created_by text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by text,
  check (kind = 'ban' or expires_at is not null)
);

create table public.moderation_actions (
  id uuid primary key default gen_random_uuid(),
  report_id uuid references public.reports(id) on delete set null,
  target_user_id uuid references public.profiles(id) on delete set null,
  action text not null,
  actor_discord_id text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.blocks (
  blocker_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create index posts_location_gix on public.posts using gist (location);
create index posts_active_idx on public.posts (expires_at, created_at desc) where deleted_at is null;
create index posts_author_active_idx on public.posts (author_id, expires_at desc) where deleted_at is null;
create index replies_post_created_idx on public.replies (post_id, created_at) where deleted_at is null;
create index reports_target_idx on public.reports (target_type, target_id);
create index reports_queue_idx on public.reports (status, created_at);
create index sanctions_active_idx on public.sanctions (user_id, kind, expires_at) where revoked_at is null;
create index moderation_actions_report_idx on public.moderation_actions (report_id, created_at);
create index blocks_blocked_idx on public.blocks (blocked_id, blocker_id);

alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.replies enable row level security;
alter table public.reports enable row level security;
alter table public.sanctions enable row level security;
alter table public.moderation_actions enable row level security;
alter table public.blocks enable row level security;

-- Profiles expose only display names to authenticated accounts; UUIDs are required for blocking.
create policy profiles_read_authenticated on public.profiles for select to authenticated using (true);
create policy profiles_insert_self on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_update_self on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- No SELECT policy exists on posts: clients must use the safe RPCs below, so geography is never readable.
create policy posts_delete_self on public.posts for delete to authenticated using (author_id = auth.uid());
create policy replies_delete_self on public.replies for delete to authenticated using (author_id = auth.uid());
create policy reports_insert_self on public.reports for insert to authenticated with check (reporter_id = auth.uid());
create policy blocks_read_self on public.blocks for select to authenticated using (blocker_id = auth.uid());
create policy blocks_insert_self on public.blocks for insert to authenticated with check (blocker_id = auth.uid());
create policy blocks_delete_self on public.blocks for delete to authenticated using (blocker_id = auth.uid());

create or replace function public.ensure_profile(display_name text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if exists(select 1 from sanctions s where s.user_id = auth.uid() and s.revoked_at is null
            and (s.expires_at is null or s.expires_at > now()) and s.kind = 'ban') then
    raise exception 'account banned';
  end if;
  insert into profiles(id, display_name) values (auth.uid(), trim(display_name))
  on conflict (id) do update set display_name = excluded.display_name;
end $$;

create or replace function public.create_nearby_post(
  body_text text, category_name text, lifetime_minutes integer, latitude double precision, longitude double precision
) returns table (
  id uuid, author_id uuid, display_name text, body text, category post_category,
  created_at timestamptz, expires_at timestamptz, approximate_distance integer, reply_count integer, is_own boolean
) language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare new_id uuid; clean_body text := trim(body_text); recent_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if exists(select 1 from sanctions s where s.user_id = auth.uid() and s.revoked_at is null
            and (s.expires_at is null or s.expires_at > now()) and s.kind in ('mute', 'ban')) then
    raise exception 'account muted';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':post', 0));
  if char_length(clean_body) not between 1 and 280 then raise exception 'invalid body'; end if;
  if lower(clean_body) ~ '(heil[[:space:]]+hitler|kill[[:space:]]+yourself)' then raise exception 'content rejected'; end if;
  if lifetime_minutes not in (30, 60, 180, 360) then raise exception 'invalid lifetime'; end if;
  if latitude not between -90 and 90 or longitude not between -180 and 180 then raise exception 'invalid coordinate'; end if;
  select count(*) into recent_count from posts p where p.author_id = auth.uid() and p.created_at > now() - interval '10 minutes';
  if recent_count >= 5 then raise exception 'rate limit exceeded'; end if;
  if exists(select 1 from posts p where p.author_id = auth.uid() and lower(p.body) = lower(clean_body) and p.created_at > now() - interval '10 minutes') then
    raise exception 'duplicate post';
  end if;
  insert into posts(author_id, body, category, location, expires_at)
  values (auth.uid(), clean_body, nullif(category_name, '')::post_category,
          st_setsrid(st_makepoint(longitude, latitude), 4326)::geography,
          now() + make_interval(mins => lifetime_minutes)) returning posts.id into new_id;
  return query select p.id, p.author_id, pr.display_name, p.body, p.category, p.created_at, p.expires_at, 0, 0, true
    from posts p join profiles pr on pr.id = p.author_id where p.id = new_id;
end $$;

create or replace function public.get_nearby_posts(latitude double precision, longitude double precision, radius_meters double precision)
returns table (
  id uuid, author_id uuid, display_name text, body text, category post_category,
  created_at timestamptz, expires_at timestamptz, approximate_distance integer, reply_count integer, is_own boolean
) language sql stable security definer set search_path = public, extensions, pg_temp as $$
  with request as (
    select st_setsrid(st_makepoint(longitude, latitude), 4326)::geography as point,
           least(greatest(radius_meters, 250), 3000) as radius
  )
  select p.id, p.author_id, pr.display_name, p.body, p.category, p.created_at, p.expires_at,
         (round(st_distance(p.location, request.point) / 25) * 25)::integer as approximate_distance,
         count(r.id)::integer as reply_count, (p.author_id = auth.uid()) as is_own
  from posts p cross join request join profiles pr on pr.id = p.author_id
  left join replies r on r.post_id = p.id and r.deleted_at is null
  where auth.uid() is not null and p.deleted_at is null and p.expires_at > now()
    and not exists (select 1 from sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                    and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
    and st_dwithin(p.location, request.point, request.radius)
    and not exists (select 1 from blocks b where b.blocker_id = auth.uid() and b.blocked_id = p.author_id)
  group by p.id, pr.display_name, request.point
  order by st_distance(p.location, request.point), p.created_at desc limit 200;
$$;

create or replace function public.get_my_active_posts()
returns table (
  id uuid, author_id uuid, display_name text, body text, category post_category,
  created_at timestamptz, expires_at timestamptz, approximate_distance integer, reply_count integer, is_own boolean
) language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, p.author_id, pr.display_name, p.body, p.category, p.created_at, p.expires_at, 0,
         count(r.id)::integer, true
  from posts p join profiles pr on pr.id = p.author_id left join replies r on r.post_id = p.id and r.deleted_at is null
  where p.author_id = auth.uid() and p.deleted_at is null and p.expires_at > now()
    and not exists (select 1 from sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                    and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
  group by p.id, pr.display_name order by p.created_at desc;
$$;

create or replace function public.get_active_replies(target_post_id uuid)
returns table (id uuid, post_id uuid, author_id uuid, display_name text, body text, created_at timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select r.id, r.post_id, r.author_id, pr.display_name, r.body, r.created_at
  from replies r join posts p on p.id = r.post_id join profiles pr on pr.id = r.author_id
  where auth.uid() is not null and r.post_id = target_post_id and r.deleted_at is null
    and p.deleted_at is null and p.expires_at > now()
    and not exists (select 1 from sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                    and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
    and not exists (select 1 from blocks b where b.blocker_id = auth.uid() and b.blocked_id = r.author_id)
  order by r.created_at;
$$;

create or replace function public.create_reply(target_post_id uuid, body_text text)
returns table (id uuid, post_id uuid, author_id uuid, display_name text, body text, created_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
declare new_id uuid; clean_body text := trim(body_text); recent_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if exists(select 1 from sanctions s where s.user_id = auth.uid() and s.revoked_at is null
            and (s.expires_at is null or s.expires_at > now()) and s.kind in ('mute', 'ban')) then
    raise exception 'account muted';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':reply', 0));
  if char_length(clean_body) not between 1 and 280 then raise exception 'invalid body'; end if;
  if lower(clean_body) ~ '(heil[[:space:]]+hitler|kill[[:space:]]+yourself)' then raise exception 'content rejected'; end if;
  if not exists(select 1 from posts p where p.id = target_post_id and p.deleted_at is null and p.expires_at > now()) then raise exception 'post expired'; end if;
  select count(*) into recent_count from replies r where r.author_id = auth.uid() and r.created_at > now() - interval '10 minutes';
  if recent_count >= 20 then raise exception 'rate limit exceeded'; end if;
  if exists(select 1 from replies r where r.author_id = auth.uid() and r.post_id = target_post_id
            and lower(r.body) = lower(clean_body) and r.created_at > now() - interval '10 minutes') then
    raise exception 'duplicate reply';
  end if;
  insert into replies(post_id, author_id, body) values(target_post_id, auth.uid(), clean_body) returning replies.id into new_id;
  return query select r.id, r.post_id, r.author_id, pr.display_name, r.body, r.created_at
    from replies r join profiles pr on pr.id = r.author_id where r.id = new_id;
end $$;

create or replace function public.delete_own_post(target_post_id uuid)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare affected integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  update posts set deleted_at = now()
  where id = target_post_id and author_id = auth.uid() and deleted_at is null;
  get diagnostics affected = row_count;
  return affected = 1;
end $$;

create or replace function public.create_report(target_type_name report_target, target_uuid uuid, reason_text text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare target_author uuid; report_id uuid; recent_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if reason_text not in ('Spam','Belästigung','Hass','Sexuelle Inhalte','Gefährliches Verhalten','Betrug','Persönliche Informationen','Sonstiges') then
    raise exception 'invalid report reason';
  end if;
  if target_type_name = 'post' then
    select p.author_id into target_author from posts p
    where p.id = target_uuid and p.deleted_at is null and p.expires_at > now();
  else
    select r.author_id into target_author from replies r join posts p on p.id = r.post_id
    where r.id = target_uuid and r.deleted_at is null and p.deleted_at is null and p.expires_at > now();
  end if;
  if target_author is null then raise exception 'target unavailable'; end if;
  if target_author = auth.uid() then raise exception 'cannot report own content'; end if;
  select count(*) into recent_count from reports where reporter_id = auth.uid() and created_at > now() - interval '1 hour';
  if recent_count >= 10 then raise exception 'report rate limit exceeded'; end if;
  insert into reports(reporter_id, target_type, target_id, reason)
  values(auth.uid(), target_type_name, target_uuid, reason_text)
  on conflict (reporter_id, target_type, target_id) do update set reason = excluded.reason
  returning id into report_id;
  return report_id;
end $$;

-- PostgREST permissions: raw tables are intentionally narrower than RPC access.
revoke all on public.posts, public.replies, public.reports, public.blocks from anon, authenticated;
revoke all on public.sanctions, public.moderation_actions from anon, authenticated;
grant delete on public.posts, public.replies to authenticated;
grant select, insert, delete on public.blocks to authenticated;
grant select, insert, update on public.profiles to authenticated;
revoke execute on function public.ensure_profile(text) from public, anon;
revoke execute on function public.create_nearby_post(text,text,integer,double precision,double precision) from public, anon;
revoke execute on function public.get_nearby_posts(double precision,double precision,double precision) from public, anon;
revoke execute on function public.get_my_active_posts() from public, anon;
revoke execute on function public.get_active_replies(uuid) from public, anon;
revoke execute on function public.create_reply(uuid,text) from public, anon;
revoke execute on function public.delete_own_post(uuid) from public, anon;
revoke execute on function public.create_report(report_target,uuid,text) from public, anon;
grant execute on function public.ensure_profile(text) to authenticated;
grant execute on function public.create_nearby_post(text,text,integer,double precision,double precision) to authenticated;
grant execute on function public.get_nearby_posts(double precision,double precision,double precision) to authenticated;
grant execute on function public.get_my_active_posts() to authenticated;
grant execute on function public.get_active_replies(uuid) to authenticated;
grant execute on function public.create_reply(uuid,text) to authenticated;
grant execute on function public.delete_own_post(uuid) to authenticated;
grant execute on function public.create_report(report_target,uuid,text) to authenticated;

-- Optional daily cleanup; visibility never depends on this job.
-- select cron.schedule('delete-expired-here-content', '17 3 * * *', $$delete from public.posts where expires_at < now() - interval '24 hours'$$);
