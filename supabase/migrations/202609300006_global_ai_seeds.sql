-- KI-Impulse are virtual, globally visible conversation starters, not local sightings.
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
         case when seed.post_id is not null then 0
              else (round(st_distance(p.location, request.point) / 25) * 25)::integer end,
         count(r.id)::integer, (p.author_id = auth.uid())
  from posts p cross join request join profiles pr on pr.id = p.author_id
  left join public.ai_bot_seeds seed on seed.post_id = p.id
  left join replies r on r.post_id = p.id and r.deleted_at is null
  where auth.uid() is not null and p.deleted_at is null and p.expires_at > now()
    and not exists (select 1 from sanctions s where s.user_id = auth.uid() and s.kind = 'ban'
                    and s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))
    and (seed.post_id is not null or st_dwithin(p.location, request.point, request.radius))
    and not exists (select 1 from blocks b where b.blocker_id = auth.uid() and b.blocked_id = p.author_id)
  group by p.id, pr.display_name, pr.is_bot, request.point, seed.post_id
  order by (seed.post_id is not null),
           case when seed.post_id is null then st_distance(p.location, request.point) end,
           p.created_at desc limit 200;
$$;

notify pgrst, 'reload schema';
