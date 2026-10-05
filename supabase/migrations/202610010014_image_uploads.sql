alter table public.profiles add column avatar_path text;
alter table public.city_clans add column icon_path text;
alter table public.posts add column image_paths text[] not null default '{}';
alter table public.support_messages add column image_paths text[] not null default '{}';

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('here-public-media', 'here-public-media', true, 2097152, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('here-support-media', 'here-support-media', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy here_public_media_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'here-public-media' and split_part(name, '/', 1) = 'users'
              and split_part(name, '/', 2) = auth.uid()::text);
create policy here_public_media_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'here-public-media' and split_part(name, '/', 1) = 'users'
         and split_part(name, '/', 2) = auth.uid()::text);
create policy here_support_media_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'here-support-media' and split_part(name, '/', 1) = 'users'
              and split_part(name, '/', 2) = auth.uid()::text);
create policy here_support_media_read_own on storage.objects for select to authenticated
  using (bucket_id = 'here-support-media' and split_part(name, '/', 1) = 'users'
         and split_part(name, '/', 2) = auth.uid()::text);
create policy here_support_media_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'here-support-media' and split_part(name, '/', 1) = 'users'
         and split_part(name, '/', 2) = auth.uid()::text);

create or replace function public.verify_uploaded_paths(paths text[], bucket_name text, folder_name text)
returns boolean language plpgsql security definer set search_path = public, storage, pg_temp as $$
declare item text;
begin
  if auth.uid() is null then return false; end if;
  if coalesce(cardinality(paths), 0) > 4 then return false; end if;
  foreach item in array coalesce(paths, '{}'::text[]) loop
    if item !~ ('^users/' || auth.uid()::text || '/' || folder_name || '/[A-Za-z0-9._/-]+$')
       or item like '%..%' or not exists (
         select 1 from storage.objects o where o.bucket_id = bucket_name and o.name = item
       ) then
      return false;
    end if;
  end loop;
  return true;
end $$;
revoke all on function public.verify_uploaded_paths(text[], text, text) from public, anon, authenticated;

create or replace function public.create_nearby_post(
  body_text text, category_name text, lifetime_minutes integer, latitude double precision,
  longitude double precision, allow_ai_reply boolean, requested_image_paths text[]
) returns table (
  id uuid, author_id uuid, display_name text, body text, category public.post_category,
  created_at timestamptz, expires_at timestamptz, approximate_distance integer,
  reply_count integer, is_own boolean, image_paths text[], avatar_path text
) language plpgsql security definer set search_path = public, extensions, storage, pg_temp as $$
declare new_id uuid; clean_body text := trim(body_text); recent_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if exists(select 1 from public.sanctions s where s.user_id = auth.uid() and s.revoked_at is null
            and (s.expires_at is null or s.expires_at > now()) and s.kind in ('mute', 'ban')) then
    raise exception 'account muted';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':post', 0));
  if char_length(clean_body) not between 1 and 280 then raise exception 'invalid body'; end if;
  if lower(clean_body) ~ '(heil[[:space:]]+hitler|kill[[:space:]]+yourself)' then raise exception 'content rejected'; end if;
  if lifetime_minutes not in (30, 60, 180, 360) then raise exception 'invalid lifetime'; end if;
  if latitude not between -90 and 90 or longitude not between -180 and 180 then raise exception 'invalid coordinate'; end if;
  if not public.verify_uploaded_paths(requested_image_paths, 'here-public-media', 'posts') then raise exception 'invalid image uploads'; end if;
  select count(*) into recent_count from public.posts p where p.author_id = auth.uid() and p.created_at > now() - interval '10 minutes';
  if recent_count >= 5 then raise exception 'rate limit exceeded'; end if;
  if exists(select 1 from public.posts p where p.author_id = auth.uid() and lower(p.body) = lower(clean_body) and p.created_at > now() - interval '10 minutes') then
    raise exception 'duplicate post';
  end if;
  insert into public.posts(author_id, body, category, location, expires_at, allow_ai_reply, image_paths)
  values (auth.uid(), clean_body, nullif(category_name, '')::public.post_category,
          st_setsrid(st_makepoint(longitude, latitude), 4326)::extensions.geography,
          now() + make_interval(mins => lifetime_minutes), coalesce(allow_ai_reply, false),
          coalesce(requested_image_paths, '{}'::text[])) returning posts.id into new_id;
  return query select p.id, p.author_id, pr.display_name, p.body, p.category, p.created_at, p.expires_at,
                      0, 0, true, p.image_paths, pr.avatar_path
    from public.posts p join public.profiles pr on pr.id = p.author_id where p.id = new_id;
end $$;
revoke execute on function public.create_nearby_post(text,text,integer,double precision,double precision,boolean,text[]) from public, anon;
grant execute on function public.create_nearby_post(text,text,integer,double precision,double precision,boolean,text[]) to authenticated;

drop function public.get_my_active_posts();
drop function public.get_nearby_posts(double precision, double precision, double precision);
create function public.get_nearby_posts(latitude double precision, longitude double precision, radius_meters double precision)
returns table (
  id uuid, author_id uuid, display_name text, body text, category public.post_category,
  created_at timestamptz, expires_at timestamptz, approximate_distance integer, reply_count integer,
  is_own boolean, image_paths text[], avatar_path text
) language sql stable security definer set search_path = public, extensions, pg_temp as $$
  with request as (
    select st_setsrid(st_makepoint(longitude, latitude), 4326)::extensions.geography as point,
           least(greatest(radius_meters, 250), 3000) as radius
  )
  select p.id, p.author_id, case when pr.is_bot then pr.display_name || ' · KI' else pr.display_name end,
         p.body, p.category, p.created_at, p.expires_at,
         case when seed.post_id is not null then 0 else (round(st_distance(p.location, request.point) / 25) * 25)::integer end,
         count(r.id)::integer, (p.author_id = auth.uid()), p.image_paths, pr.avatar_path
    from public.posts p cross join request join public.profiles pr on pr.id = p.author_id
    left join public.ai_bot_seeds seed on seed.post_id = p.id
    left join public.replies r on r.post_id = p.id and r.deleted_at is null
   where auth.uid() is not null and p.deleted_at is null and p.expires_at > now()
     and not exists (select 1 from public.sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                     and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
     and (seed.post_id is not null or st_dwithin(p.location, request.point, request.radius))
     and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = p.author_id)
   group by p.id, pr.display_name, pr.is_bot, pr.avatar_path, request.point, seed.post_id
   order by (seed.post_id is not null), case when seed.post_id is null then st_distance(p.location, request.point) end,
            p.created_at desc limit 200;
$$;
create function public.get_my_active_posts()
returns table (
  id uuid, author_id uuid, display_name text, body text, category public.post_category,
  created_at timestamptz, expires_at timestamptz, approximate_distance integer, reply_count integer,
  is_own boolean, image_paths text[], avatar_path text
) language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, p.author_id, case when pr.is_bot then pr.display_name || ' · KI' else pr.display_name end,
         p.body, p.category, p.created_at, p.expires_at, 0, count(r.id)::integer, true, p.image_paths, pr.avatar_path
    from public.posts p join public.profiles pr on pr.id = p.author_id
    left join public.replies r on r.post_id = p.id and r.deleted_at is null
   where p.author_id = auth.uid() and p.deleted_at is null and p.expires_at > now()
     and not exists (select 1 from public.sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                     and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
   group by p.id, pr.display_name, pr.is_bot, pr.avatar_path order by p.created_at desc;
$$;

drop function public.get_active_replies(uuid);
create function public.get_active_replies(target_post_id uuid)
returns table (id uuid, post_id uuid, author_id uuid, display_name text, body text, created_at timestamptz, avatar_path text)
language sql stable security definer set search_path = public, pg_temp as $$
  select r.id, r.post_id, r.author_id, case when pr.is_bot then pr.display_name || ' · KI' else pr.display_name end,
         r.body, r.created_at, pr.avatar_path
    from public.replies r join public.posts p on p.id = r.post_id join public.profiles pr on pr.id = r.author_id
   where auth.uid() is not null and r.post_id = target_post_id and r.deleted_at is null
     and p.deleted_at is null and p.expires_at > now()
     and not exists (select 1 from public.sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                     and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
     and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = r.author_id)
   order by r.created_at;
$$;
revoke execute on function public.get_nearby_posts(double precision,double precision,double precision) from public, anon;
revoke execute on function public.get_my_active_posts() from public, anon;
revoke execute on function public.get_active_replies(uuid) from public, anon;
grant execute on function public.get_nearby_posts(double precision,double precision,double precision) to authenticated;
grant execute on function public.get_my_active_posts() to authenticated;
grant execute on function public.get_active_replies(uuid) to authenticated;

create or replace function public.set_my_avatar(requested_path text)
returns text language plpgsql security definer set search_path = public, storage, pg_temp as $$
begin
  if not public.verify_uploaded_paths(array[requested_path], 'here-public-media', 'avatars') then raise exception 'invalid image upload'; end if;
  update public.profiles set avatar_path = requested_path where id = auth.uid();
  return requested_path;
end $$;
create or replace function public.get_my_avatar()
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select p.avatar_path from public.profiles p where p.id = auth.uid();
$$;
create or replace function public.set_city_clan_icon(target_clan_id uuid, requested_path text)
returns text language plpgsql security definer set search_path = public, storage, pg_temp as $$
begin
  if not exists(select 1 from public.city_clan_memberships m where m.user_id = auth.uid() and m.clan_id = target_clan_id) then
    raise exception 'not a clan member';
  end if;
  if not public.verify_uploaded_paths(array[requested_path], 'here-public-media', 'clans')
     or requested_path !~ ('^users/' || auth.uid()::text || '/clans/' || target_clan_id::text || '/[A-Za-z0-9._/-]+$') then
    raise exception 'invalid image upload';
  end if;
  update public.city_clans set icon_path = requested_path where id = target_clan_id;
  return requested_path;
end $$;
revoke execute on function public.set_my_avatar(text) from public, anon;
revoke execute on function public.set_city_clan_icon(uuid,text) from public, anon;
revoke execute on function public.get_my_avatar() from public, anon;
grant execute on function public.set_my_avatar(text) to authenticated;
grant execute on function public.set_city_clan_icon(uuid,text) to authenticated;
grant execute on function public.get_my_avatar() to authenticated;

drop function public.get_my_city_clan();
drop function public.get_city_clan_leaderboard();
create function public.get_city_clan_leaderboard()
returns table (clan_id uuid, city_name text, clan_level text, member_count integer,
               weekly_points integer, weekly_rank bigint, icon_path text)
language sql stable security definer set search_path = public, pg_temp as $$
  with members as (select m.clan_id, count(*)::integer as total from public.city_clan_memberships m group by m.clan_id),
  scores as (select e.clan_id, sum(e.points)::integer as total from public.city_clan_score_events e
              where e.created_at >= date_trunc('week', now()) group by e.clan_id),
  ranked as (
    select c.id as ranked_clan_id, c.city_name as ranked_city_name, c.clan_level as ranked_clan_level,
           coalesce(m.total, 0)::integer as ranked_member_count, coalesce(s.total, 0)::integer as ranked_points,
           rank() over(partition by c.clan_level order by coalesce(s.total, 0) desc) as ranked_weekly_rank,
           c.icon_path as ranked_icon_path
      from public.city_clans c join members m on m.clan_id = c.id left join scores s on s.clan_id = c.id
  )
  select ranked.ranked_clan_id, ranked.ranked_city_name, ranked.ranked_clan_level, ranked.ranked_member_count,
         ranked.ranked_points, ranked.ranked_weekly_rank, ranked.ranked_icon_path
    from ranked order by ranked.ranked_clan_level, ranked.ranked_weekly_rank, ranked.ranked_city_name limit 500;
$$;
create function public.get_my_city_clan()
returns table (clan_id uuid, city_name text, clan_level text, member_count integer,
               weekly_points integer, weekly_rank bigint, switch_available_at timestamptz, icon_path text)
language sql stable security definer set search_path = public, pg_temp as $$
  select l.clan_id, l.city_name, l.clan_level, l.member_count, l.weekly_points, l.weekly_rank,
         m.changed_at + interval '7 days', l.icon_path
    from public.city_clan_memberships m join public.get_city_clan_leaderboard() l on l.clan_id = m.clan_id
   where m.user_id = auth.uid()
  union all
  select null::uuid, null::text, 'municipal'::text, 0, 0, null::bigint, null::timestamptz, null::text
   where auth.uid() is not null and not exists(select 1 from public.city_clan_memberships m where m.user_id = auth.uid());
$$;
revoke execute on function public.get_city_clan_leaderboard() from public, anon;
revoke execute on function public.get_my_city_clan() from public, anon;
grant execute on function public.get_city_clan_leaderboard() to authenticated;
grant execute on function public.get_my_city_clan() to authenticated;

drop function public.get_support_ticket();
create function public.get_support_ticket()
returns table (
  ticket_id uuid, ticket_status text, assigned_staff_name text, ticket_created_at timestamptz,
  message_id uuid, message_sender text, message_body text, message_staff_name text,
  message_created_at timestamptz, image_paths text[]
) language sql stable security definer set search_path = public, pg_temp as $$
  with selected as (
    select t.* from public.support_tickets t where t.user_id = auth.uid()
    order by case when t.status in ('pending', 'open', 'closing') then 0 else 1 end, t.created_at desc limit 1
  )
  select t.id, t.status::text, t.assigned_staff_name, t.created_at, m.id, m.sender::text, m.body,
         m.staff_display_name, m.created_at, m.image_paths
    from selected t left join public.support_messages m on m.ticket_id = t.id order by m.created_at, m.id;
$$;

create or replace function public.open_support_ticket(first_message text, requested_image_paths text[])
returns uuid language plpgsql security definer set search_path = public, storage, pg_temp as $$
declare clean_body text := trim(first_message); v_ticket_id uuid; recent_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if char_length(clean_body) not between 1 and 1500 then raise exception 'invalid support message'; end if;
  if not public.verify_uploaded_paths(requested_image_paths, 'here-support-media', 'support') then raise exception 'invalid image uploads'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':support', 0));
  select id into v_ticket_id from public.support_tickets where user_id = auth.uid() and status in ('pending', 'open') order by created_at desc limit 1;
  if v_ticket_id is null then insert into public.support_tickets(user_id) values(auth.uid()) returning id into v_ticket_id; end if;
  select count(*) into recent_count from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
   where t.user_id = auth.uid() and m.sender = 'user' and m.created_at > now() - interval '1 minute';
  if recent_count >= 8 then raise exception 'support rate limit exceeded'; end if;
  insert into public.support_messages(ticket_id, sender, body, image_paths)
    values(v_ticket_id, 'user', clean_body, coalesce(requested_image_paths, '{}'::text[]));
  update public.support_tickets set updated_at = now() where id = v_ticket_id;
  return v_ticket_id;
end $$;
create or replace function public.send_support_message(target_ticket_id uuid, message_text text, requested_image_paths text[])
returns uuid language plpgsql security definer set search_path = public, storage, pg_temp as $$
declare clean_body text := trim(message_text); message_id uuid; recent_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if char_length(clean_body) not between 1 and 1500 then raise exception 'invalid support message'; end if;
  if not public.verify_uploaded_paths(requested_image_paths, 'here-support-media', 'support') then raise exception 'invalid image uploads'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_ticket_id::text || ':support-message', 0));
  if not exists(select 1 from public.support_tickets where id = target_ticket_id and user_id = auth.uid() and status in ('pending', 'open')) then raise exception 'support ticket unavailable'; end if;
  select count(*) into recent_count from public.support_messages where ticket_id = target_ticket_id and sender = 'user' and created_at > now() - interval '1 minute';
  if recent_count >= 8 then raise exception 'support rate limit exceeded'; end if;
  insert into public.support_messages(ticket_id, sender, body, image_paths)
    values(target_ticket_id, 'user', clean_body, coalesce(requested_image_paths, '{}'::text[])) returning id into message_id;
  update public.support_tickets set updated_at = now() where id = target_ticket_id;
  return message_id;
end $$;
revoke execute on function public.open_support_ticket(text,text[]) from public, anon;
revoke execute on function public.send_support_message(uuid,text,text[]) from public, anon;
grant execute on function public.open_support_ticket(text,text[]) to authenticated;
grant execute on function public.send_support_message(uuid,text,text[]) to authenticated;
notify pgrst, 'reload schema';
