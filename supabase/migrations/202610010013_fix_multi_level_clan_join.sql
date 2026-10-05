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

revoke execute on function public.join_city_clan(text, text) from public, anon;
grant execute on function public.join_city_clan(text, text) to authenticated;
notify pgrst, 'reload schema';
