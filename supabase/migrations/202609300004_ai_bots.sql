-- Verified AI accounts are explicit, never hidden among human profiles.
alter table public.profiles add column if not exists is_bot boolean not null default false;
alter table public.profiles add constraint profiles_no_fake_ai_label
  check (display_name not like '% · KI');

create or replace function public.protect_bot_profile()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if auth.role() in ('anon', 'authenticated') and new.is_bot then
    raise exception 'bot identity is reserved';
  end if;
  return new;
end $$;

create trigger protect_bot_profile before insert or update on public.profiles
for each row execute function public.protect_bot_profile();

create table public.ai_bot_replies (
  post_id uuid primary key references public.posts(id) on delete cascade,
  reply_id uuid not null unique references public.replies(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table public.ai_bot_seeds (
  post_id uuid primary key references public.posts(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table public.ai_bot_skips (
  post_id uuid primary key references public.posts(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.ai_bot_replies enable row level security;
alter table public.ai_bot_seeds enable row level security;
alter table public.ai_bot_skips enable row level security;

create or replace function public.get_nearby_posts(latitude double precision, longitude double precision, radius_meters double precision)
returns table (
  id uuid, author_id uuid, display_name text, body text, category post_category,
  created_at timestamptz, expires_at timestamptz, approximate_distance integer, reply_count integer, is_own boolean
) language sql stable security definer set search_path = public, extensions, pg_temp as $$
  with request as (
    select st_setsrid(st_makepoint(longitude, latitude), 4326)::geography as point,
           least(greatest(radius_meters, 250), 3000) as radius
  )
  select p.id, p.author_id,
         case when pr.is_bot then pr.display_name || ' · KI' else pr.display_name end,
         p.body, p.category, p.created_at, p.expires_at,
         (round(st_distance(p.location, request.point) / 25) * 25)::integer,
         count(r.id)::integer, (p.author_id = auth.uid())
  from posts p cross join request join profiles pr on pr.id = p.author_id
  left join replies r on r.post_id = p.id and r.deleted_at is null
  where auth.uid() is not null and p.deleted_at is null and p.expires_at > now()
    and not exists (select 1 from sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                    and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
    and st_dwithin(p.location, request.point, request.radius)
    and not exists (select 1 from blocks b where b.blocker_id = auth.uid() and b.blocked_id = p.author_id)
  group by p.id, pr.display_name, pr.is_bot, request.point
  order by st_distance(p.location, request.point), p.created_at desc limit 200;
$$;

create or replace function public.get_my_active_posts()
returns table (
  id uuid, author_id uuid, display_name text, body text, category post_category,
  created_at timestamptz, expires_at timestamptz, approximate_distance integer, reply_count integer, is_own boolean
) language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, p.author_id,
         case when pr.is_bot then pr.display_name || ' · KI' else pr.display_name end,
         p.body, p.category, p.created_at, p.expires_at, 0,
         count(r.id)::integer, true
  from posts p join profiles pr on pr.id = p.author_id left join replies r on r.post_id = p.id and r.deleted_at is null
  where p.author_id = auth.uid() and p.deleted_at is null and p.expires_at > now()
    and not exists (select 1 from sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                    and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
  group by p.id, pr.display_name, pr.is_bot order by p.created_at desc;
$$;

create or replace function public.get_active_replies(target_post_id uuid)
returns table (id uuid, post_id uuid, author_id uuid, display_name text, body text, created_at timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select r.id, r.post_id, r.author_id,
         case when pr.is_bot then pr.display_name || ' · KI' else pr.display_name end,
         r.body, r.created_at
  from replies r join posts p on p.id = r.post_id join profiles pr on pr.id = r.author_id
  where auth.uid() is not null and r.post_id = target_post_id and r.deleted_at is null
    and p.deleted_at is null and p.expires_at > now()
    and not exists (select 1 from sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                    and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
    and not exists (select 1 from blocks b where b.blocker_id = auth.uid() and b.blocked_id = r.author_id)
  order by r.created_at;
$$;

notify pgrst, 'reload schema';
