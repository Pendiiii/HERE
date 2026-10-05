alter table public.city_clans
  add column clan_level text not null default 'municipal'
    check (clan_level in ('open', 'municipal', 'county', 'state', 'national'));

alter table public.city_clans drop constraint city_clans_city_key_key;
alter table public.city_clans add constraint city_clans_level_city_key_key unique (clan_level, city_key);

alter table public.profiles
  add column city_clan_level_changed_at timestamptz;

create index city_clans_level_key_idx on public.city_clans(clan_level, city_key);

drop function public.get_my_city_clan();
drop function public.get_city_clan_leaderboard();
drop function public.join_city_clan(text);

create or replace function public.join_city_clan(requested_name text, requested_level text)
returns table (
  clan_id uuid, city_name text, clan_level text, member_count integer, weekly_points integer,
  weekly_rank bigint, switch_available_at timestamptz
) language plpgsql security definer set search_path = public, pg_temp as $$
declare
  clean_name text := regexp_replace(trim(requested_name), '[[:space:]]+', ' ', 'g');
  normalized_name text;
  target_clan_id uuid;
  member_row public.profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if requested_level not in ('open', 'municipal', 'county', 'state', 'national') then
    raise exception 'invalid clan level';
  end if;
  if char_length(clean_name) not between 2 and 48
     or left(clean_name, 1) !~ '[[:alpha:]]'
     or clean_name ~ '[^[:alpha:][:space:]’.,0-9-]' then
    raise exception 'invalid city name';
  end if;
  normalized_name := lower(clean_name);
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':city-clan', 0));

  select * into member_row from public.profiles where id = auth.uid() for update;
  if not found then raise exception 'profile required'; end if;
  if member_row.is_bot then raise exception 'bots cannot join city clans'; end if;

  insert into public.city_clans(city_name, city_key, clan_level)
    values(clean_name, normalized_name, requested_level)
    on conflict on constraint city_clans_level_city_key_key do nothing;
  select c.id into target_clan_id from public.city_clans c
   where c.clan_level = requested_level and c.city_key = normalized_name;

  if member_row.city_clan_id is not null and member_row.city_clan_id <> target_clan_id
     and coalesce(member_row.city_clan_level_changed_at, member_row.city_clan_changed_at) > now() - interval '7 days' then
    raise exception 'clan switch cooldown active';
  end if;

  if member_row.city_clan_id is distinct from target_clan_id then
    update public.profiles
       set city_clan_id = target_clan_id,
           city_clan_level_changed_at = now(),
           city_clan_changed_at = now()
     where id = auth.uid();
  end if;

  return query select result.clan_id, result.city_name, result.clan_level,
                      result.member_count, result.weekly_points, result.weekly_rank,
                      case when member_row.city_clan_id = target_clan_id
                           then coalesce(member_row.city_clan_level_changed_at, member_row.city_clan_changed_at) + interval '7 days'
                           else now() + interval '7 days' end
    from public.get_city_clan_leaderboard() result where result.clan_id = target_clan_id;
end $$;

create or replace function public.get_city_clan_leaderboard()
returns table (
  clan_id uuid, city_name text, clan_level text, member_count integer,
  weekly_points integer, weekly_rank bigint
) language sql stable security definer set search_path = public, pg_temp as $$
  with members as (
    select p.city_clan_id, count(*)::integer as total
      from public.profiles p where p.city_clan_id is not null group by p.city_clan_id
  ), scores as (
    select e.clan_id, sum(e.points)::integer as total
      from public.city_clan_score_events e
     where e.created_at >= date_trunc('week', now()) group by e.clan_id
  ), ranked as (
    select c.id as ranked_clan_id, c.city_name as ranked_city_name, c.clan_level as ranked_clan_level,
           coalesce(m.total, 0)::integer as ranked_member_count,
           coalesce(s.total, 0)::integer as ranked_points,
           rank() over(partition by c.clan_level order by coalesce(s.total, 0) desc) as ranked_weekly_rank
      from public.city_clans c
      join members m on m.city_clan_id = c.id
      left join scores s on s.clan_id = c.id
  )
  select ranked.ranked_clan_id, ranked.ranked_city_name, ranked.ranked_clan_level,
         ranked.ranked_member_count, ranked.ranked_points, ranked.ranked_weekly_rank
    from ranked order by ranked.ranked_clan_level, ranked.ranked_weekly_rank, ranked.ranked_city_name limit 500;
$$;

create function public.join_city_clan(requested_city text)
returns table (
  clan_id uuid, city_name text, member_count integer, weekly_points integer,
  weekly_rank bigint, switch_available_at timestamptz
) language plpgsql security definer set search_path = public, pg_temp as $$
begin
  return query select result.clan_id, result.city_name, result.member_count,
                      result.weekly_points, result.weekly_rank, result.switch_available_at
    from public.join_city_clan(requested_city, 'municipal') result;
end $$;

create or replace function public.get_my_city_clan()
returns table (
  clan_id uuid, city_name text, clan_level text, member_count integer, weekly_points integer,
  weekly_rank bigint, switch_available_at timestamptz
) language sql stable security definer set search_path = public, pg_temp as $$
  select l.clan_id, l.city_name, l.clan_level, l.member_count, l.weekly_points, l.weekly_rank,
         coalesce(p.city_clan_level_changed_at, p.city_clan_changed_at) + interval '7 days'
    from public.profiles p
    join public.get_city_clan_leaderboard() l on l.clan_id = p.city_clan_id
   where p.id = auth.uid()
  union all
  select null::uuid, null::text, 'municipal'::text, 0, 0, null::bigint, null::timestamptz
   where auth.uid() is not null and not exists (
     select 1 from public.profiles p where p.id = auth.uid() and p.city_clan_id is not null
   );
$$;

revoke execute on function public.join_city_clan(text) from public, anon;
revoke execute on function public.join_city_clan(text, text) from public, anon;
grant execute on function public.join_city_clan(text, text) to authenticated;
grant execute on function public.join_city_clan(text) to authenticated;
notify pgrst, 'reload schema';
