-- Existing posts stay opted out. Only the new six-argument RPC can opt in.
alter table public.posts add column allow_ai_reply boolean not null default false;

create function public.create_nearby_post(
  body_text text, category_name text, lifetime_minutes integer, latitude double precision, longitude double precision,
  allow_ai_reply boolean
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
  insert into posts(author_id, body, category, location, expires_at, allow_ai_reply)
  values (auth.uid(), clean_body, nullif(category_name, '')::post_category,
          st_setsrid(st_makepoint(longitude, latitude), 4326)::geography,
          now() + make_interval(mins => lifetime_minutes), coalesce(allow_ai_reply, false)) returning posts.id into new_id;
  return query select p.id, p.author_id, pr.display_name, p.body, p.category, p.created_at, p.expires_at, 0, 0, true
    from posts p join profiles pr on pr.id = p.author_id where p.id = new_id;
end $$;

revoke execute on function public.create_nearby_post(text,text,integer,double precision,double precision,boolean) from public, anon;
grant execute on function public.create_nearby_post(text,text,integer,double precision,double precision,boolean) to authenticated;
notify pgrst, 'reload schema';
