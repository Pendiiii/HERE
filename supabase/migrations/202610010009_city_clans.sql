create table public.city_clans (
  id uuid primary key default gen_random_uuid(),
  city_name text not null check (char_length(city_name) between 2 and 48),
  city_key text not null unique,
  created_at timestamptz not null default now()
);

alter table public.profiles
  add column city_clan_id uuid references public.city_clans(id) on delete set null,
  add column city_clan_changed_at timestamptz;

create index profiles_city_clan_idx on public.profiles(city_clan_id) where city_clan_id is not null;

create table public.city_clan_score_events (
  id uuid primary key default gen_random_uuid(),
  clan_id uuid not null references public.city_clans(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  source_type text not null check (source_type in ('post', 'reply')),
  source_id uuid not null,
  points smallint not null check (points between 1 and 3),
  created_at timestamptz not null default now(),
  unique(source_type, source_id)
);

create index city_clan_score_weekly_idx on public.city_clan_score_events(clan_id, created_at desc);
create index city_clan_score_user_day_idx on public.city_clan_score_events(user_id, created_at desc);
alter table public.city_clans enable row level security;
alter table public.city_clan_score_events enable row level security;
revoke all on public.city_clans, public.city_clan_score_events from anon, authenticated;

create or replace function public.join_city_clan(requested_city text)
returns table (
  clan_id uuid, city_name text, member_count integer, weekly_points integer,
  weekly_rank bigint, switch_available_at timestamptz
) language plpgsql security definer set search_path = public, pg_temp as $$
declare
  clean_city text := regexp_replace(trim(requested_city), '[[:space:]]+', ' ', 'g');
  normalized_city text;
  target_clan_id uuid;
  member_row public.profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if char_length(clean_city) not between 2 and 48
     or left(clean_city, 1) !~ '[[:alpha:]]'
     or clean_city ~ '[^[:alpha:][:space:]’.,0-9-]' then
    raise exception 'invalid city name';
  end if;
  normalized_city := lower(clean_city);
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':city-clan', 0));

  select * into member_row from public.profiles where id = auth.uid() for update;
  if not found then raise exception 'profile required'; end if;
  if member_row.is_bot then raise exception 'bots cannot join city clans'; end if;

  insert into public.city_clans(city_name, city_key) values(clean_city, normalized_city)
    on conflict (city_key) do nothing;
  select c.id into target_clan_id from public.city_clans c where c.city_key = normalized_city;

  if member_row.city_clan_id is not null and member_row.city_clan_id <> target_clan_id
     and member_row.city_clan_changed_at > now() - interval '7 days' then
    raise exception 'clan switch cooldown active';
  end if;

  if member_row.city_clan_id is distinct from target_clan_id then
    update public.profiles set city_clan_id = target_clan_id, city_clan_changed_at = now()
     where id = auth.uid();
  end if;

  return query select result.clan_id, result.city_name, result.member_count,
                      result.weekly_points, result.weekly_rank,
                      member_row.city_clan_changed_at + interval '7 days'
    from public.get_city_clan_leaderboard() result where result.clan_id = target_clan_id;
end $$;

create or replace function public.get_city_clan_leaderboard()
returns table (
  clan_id uuid, city_name text, member_count integer, weekly_points integer, weekly_rank bigint
) language sql stable security definer set search_path = public, pg_temp as $$
  with members as (
    select p.city_clan_id, count(*)::integer as total
      from public.profiles p where p.city_clan_id is not null group by p.city_clan_id
  ), scores as (
    select e.clan_id, sum(e.points)::integer as total
      from public.city_clan_score_events e
     where e.created_at >= date_trunc('week', now()) group by e.clan_id
  ), ranked as (
    select c.id as ranked_clan_id, c.city_name as ranked_city_name,
           coalesce(m.total, 0)::integer as ranked_member_count,
           coalesce(s.total, 0)::integer as ranked_points,
           rank() over(order by coalesce(s.total, 0) desc) as ranked_weekly_rank
      from public.city_clans c
      join members m on m.city_clan_id = c.id
      left join scores s on s.clan_id = c.id
  )
  select ranked.ranked_clan_id, ranked.ranked_city_name, ranked.ranked_member_count,
         ranked.ranked_points, ranked.ranked_weekly_rank
    from ranked order by ranked.ranked_weekly_rank, ranked.ranked_city_name limit 100;
$$;

create or replace function public.get_my_city_clan()
returns table (
  clan_id uuid, city_name text, member_count integer, weekly_points integer,
  weekly_rank bigint, switch_available_at timestamptz
) language sql stable security definer set search_path = public, pg_temp as $$
  select l.clan_id, l.city_name, l.member_count, l.weekly_points, l.weekly_rank,
         p.city_clan_changed_at + interval '7 days'
    from public.profiles p
    join public.get_city_clan_leaderboard() l on l.clan_id = p.city_clan_id
   where p.id = auth.uid()
  union all
  select null::uuid, null::text, 0, 0, null::bigint, null::timestamptz
   where auth.uid() is not null and not exists (
     select 1 from public.profiles p where p.id = auth.uid() and p.city_clan_id is not null
   );
$$;

create or replace function public.award_city_clan_points()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  member_clan_id uuid;
  earned_points smallint;
  points_today integer;
  kind text := case when tg_table_name = 'posts' then 'post' else 'reply' end;
begin
  select p.city_clan_id into member_clan_id from public.profiles p
   where p.id = new.author_id and not p.is_bot;
  if member_clan_id is null then return new; end if;

  perform pg_advisory_xact_lock(hashtextextended(new.author_id::text || ':city-clan-score', 0));
  earned_points := case when kind = 'post' then 3 else 1 end;
  select coalesce(sum(e.points), 0)::integer into points_today
    from public.city_clan_score_events e
   where e.user_id = new.author_id and e.created_at >= date_trunc('day', now());
  if points_today + earned_points > 15 then return new; end if;

  insert into public.city_clan_score_events(clan_id, user_id, source_type, source_id, points)
    values(member_clan_id, new.author_id, kind, new.id, earned_points)
    on conflict(source_type, source_id) do nothing;
  return new;
end $$;

create or replace function public.remove_deleted_city_clan_points()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.deleted_at is null and new.deleted_at is not null then
    if tg_table_name = 'posts' then
      delete from public.city_clan_score_events e
       where (e.source_type = 'post' and e.source_id = new.id)
          or (e.source_type = 'reply' and e.source_id in
              (select r.id from public.replies r where r.post_id = new.id));
    else
      delete from public.city_clan_score_events
       where source_type = 'reply' and source_id = new.id;
    end if;
  end if;
  return new;
end $$;

create trigger award_city_clan_post_points after insert on public.posts
  for each row execute function public.award_city_clan_points();
create trigger award_city_clan_reply_points after insert on public.replies
  for each row execute function public.award_city_clan_points();
create trigger remove_deleted_city_clan_post_points after update of deleted_at on public.posts
  for each row execute function public.remove_deleted_city_clan_points();
create trigger remove_deleted_city_clan_reply_points after update of deleted_at on public.replies
  for each row execute function public.remove_deleted_city_clan_points();

revoke execute on function public.join_city_clan(text) from public, anon;
revoke execute on function public.get_city_clan_leaderboard() from public, anon;
revoke execute on function public.get_my_city_clan() from public, anon;
grant execute on function public.join_city_clan(text) to authenticated;
grant execute on function public.get_city_clan_leaderboard() to authenticated;
grant execute on function public.get_my_city_clan() to authenticated;

notify pgrst, 'reload schema';
