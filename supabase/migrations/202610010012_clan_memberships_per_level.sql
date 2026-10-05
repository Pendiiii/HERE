alter table public.city_clans add constraint city_clans_id_level_key unique (id, clan_level);

create table public.city_clan_memberships (
  user_id uuid not null references public.profiles(id) on delete cascade,
  clan_id uuid not null,
  clan_level text not null check (clan_level in ('open', 'municipal', 'county', 'state', 'national')),
  changed_at timestamptz not null default now(),
  primary key(user_id, clan_id),
  unique(user_id, clan_level),
  foreign key(clan_id, clan_level) references public.city_clans(id, clan_level) on delete cascade
);
create index city_clan_memberships_clan_idx on public.city_clan_memberships(clan_id);
alter table public.city_clan_memberships enable row level security;
revoke all on public.city_clan_memberships from anon, authenticated;

insert into public.city_clan_memberships(user_id, clan_id, clan_level, changed_at)
select p.id, c.id, c.clan_level, coalesce(p.city_clan_level_changed_at, p.city_clan_changed_at, now())
  from public.profiles p join public.city_clans c on c.id = p.city_clan_id
on conflict (user_id, clan_level) do nothing;

alter table public.city_clan_score_events add column clan_level text;
update public.city_clan_score_events e set clan_level = c.clan_level
  from public.city_clans c where c.id = e.clan_id;
alter table public.city_clan_score_events alter column clan_level set not null;
alter table public.city_clan_score_events add constraint city_clan_score_events_level_check
  check (clan_level in ('open', 'municipal', 'county', 'state', 'national'));
alter table public.city_clan_score_events drop constraint city_clan_score_events_source_type_source_id_key;
alter table public.city_clan_score_events add constraint city_clan_score_events_clan_source_key
  unique(clan_id, source_type, source_id);

create or replace function public.join_city_clan(requested_name text, requested_level text)
returns table (
  clan_id uuid, city_name text, clan_level text, member_count integer, weekly_points integer,
  weekly_rank bigint, switch_available_at timestamptz
) language plpgsql security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  clean_name text := regexp_replace(trim(requested_name), '[[:space:]]+', ' ', 'g');
  normalized_name text;
  target_clan_id uuid;
  member_row public.profiles%rowtype;
  current_membership public.city_clan_memberships%rowtype;
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
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':city-clan:' || requested_level, 0));

  select * into member_row from public.profiles where id = auth.uid();
  if not found then raise exception 'profile required'; end if;
  if member_row.is_bot then raise exception 'bots cannot join city clans'; end if;

  insert into public.city_clans(city_name, city_key, clan_level)
    values(clean_name, normalized_name, requested_level)
    on conflict on constraint city_clans_level_city_key_key do nothing;
  select c.id into target_clan_id from public.city_clans c
   where c.clan_level = requested_level and c.city_key = normalized_name;

  select * into current_membership from public.city_clan_memberships m
   where m.user_id = auth.uid() and m.clan_level = requested_level for update;
  if found and current_membership.clan_id <> target_clan_id
     and current_membership.changed_at > now() - interval '7 days' then
    raise exception 'clan switch cooldown active';
  end if;

  if not found or current_membership.clan_id <> target_clan_id then
    insert into public.city_clan_memberships(user_id, clan_id, clan_level, changed_at)
      values(auth.uid(), target_clan_id, requested_level, now())
      on conflict (user_id, clan_level) do update
        set clan_id = excluded.clan_id, changed_at = excluded.changed_at;
    if requested_level = 'municipal' then
      update public.profiles set city_clan_id = target_clan_id,
                                 city_clan_changed_at = now(), city_clan_level_changed_at = now()
       where id = auth.uid();
    end if;
  end if;

  return query select result.clan_id, result.city_name, result.clan_level,
                      result.member_count, result.weekly_points, result.weekly_rank,
                      case when current_membership.clan_id = target_clan_id
                           then current_membership.changed_at + interval '7 days'
                           else now() + interval '7 days' end
    from public.get_city_clan_leaderboard() result where result.clan_id = target_clan_id;
end $$;

create or replace function public.get_city_clan_leaderboard()
returns table (
  clan_id uuid, city_name text, clan_level text, member_count integer,
  weekly_points integer, weekly_rank bigint
) language sql stable security definer set search_path = public, pg_temp as $$
  with members as (
    select m.clan_id, count(*)::integer as total
      from public.city_clan_memberships m group by m.clan_id
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
      join members m on m.clan_id = c.id
      left join scores s on s.clan_id = c.id
  )
  select ranked.ranked_clan_id, ranked.ranked_city_name, ranked.ranked_clan_level,
         ranked.ranked_member_count, ranked.ranked_points, ranked.ranked_weekly_rank
    from ranked order by ranked.ranked_clan_level, ranked.ranked_weekly_rank, ranked.ranked_city_name limit 500;
$$;

create or replace function public.get_my_city_clan()
returns table (
  clan_id uuid, city_name text, clan_level text, member_count integer, weekly_points integer,
  weekly_rank bigint, switch_available_at timestamptz
) language sql stable security definer set search_path = public, pg_temp as $$
  select l.clan_id, l.city_name, l.clan_level, l.member_count, l.weekly_points, l.weekly_rank,
         m.changed_at + interval '7 days'
    from public.city_clan_memberships m
    join public.get_city_clan_leaderboard() l on l.clan_id = m.clan_id
   where m.user_id = auth.uid()
  union all
  select null::uuid, null::text, 'municipal'::text, 0, 0, null::bigint, null::timestamptz
   where auth.uid() is not null and not exists (
     select 1 from public.city_clan_memberships m where m.user_id = auth.uid()
   );
$$;

create or replace function public.award_city_clan_points()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  member_row record;
  earned_points smallint;
  points_today integer;
  kind text := case when tg_table_name = 'posts' then 'post' else 'reply' end;
begin
  if exists(select 1 from public.profiles p where p.id = new.author_id and p.is_bot) then return new; end if;
  earned_points := case when kind = 'post' then 3 else 1 end;
  perform pg_advisory_xact_lock(hashtextextended(new.author_id::text || ':city-clan-score', 0));

  for member_row in select m.clan_id, m.clan_level from public.city_clan_memberships m
                     where m.user_id = new.author_id loop
    select coalesce(sum(e.points), 0)::integer into points_today
      from public.city_clan_score_events e
     where e.user_id = new.author_id and e.clan_level = member_row.clan_level
       and e.created_at >= date_trunc('day', now());
    if points_today + earned_points <= 15 then
      insert into public.city_clan_score_events(clan_id, clan_level, user_id, source_type, source_id, points)
        values(member_row.clan_id, member_row.clan_level, new.author_id, kind, new.id, earned_points)
        on conflict(clan_id, source_type, source_id) do nothing;
    end if;
  end loop;
  return new;
end $$;

revoke execute on function public.join_city_clan(text, text) from public, anon;
grant execute on function public.join_city_clan(text, text) to authenticated;
notify pgrst, 'reload schema';
