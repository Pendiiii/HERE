-- Swift's UUID.uuidString uses uppercase hex; PostgreSQL renders UUIDs in lowercase.
-- Compare only the UUID path segment case-insensitively, without relaxing ownership.
alter policy here_public_media_insert_own on storage.objects
  with check (bucket_id = 'here-public-media' and split_part(name, '/', 1) = 'users'
              and lower(split_part(name, '/', 2)) = auth.uid()::text);
alter policy here_public_media_delete_own on storage.objects
  using (bucket_id = 'here-public-media' and split_part(name, '/', 1) = 'users'
         and lower(split_part(name, '/', 2)) = auth.uid()::text);
alter policy here_support_media_insert_own on storage.objects
  with check (bucket_id = 'here-support-media' and split_part(name, '/', 1) = 'users'
              and lower(split_part(name, '/', 2)) = auth.uid()::text);
alter policy here_support_media_read_own on storage.objects
  using (bucket_id = 'here-support-media' and split_part(name, '/', 1) = 'users'
         and lower(split_part(name, '/', 2)) = auth.uid()::text);
alter policy here_support_media_delete_own on storage.objects
  using (bucket_id = 'here-support-media' and split_part(name, '/', 1) = 'users'
         and lower(split_part(name, '/', 2)) = auth.uid()::text);

create or replace function public.verify_uploaded_paths(paths text[], bucket_name text, folder_name text)
returns boolean language plpgsql security definer set search_path = public, storage, pg_temp as $$
declare item text;
begin
  if auth.uid() is null then return false; end if;
  if coalesce(cardinality(paths), 0) > 4 then return false; end if;
  foreach item in array coalesce(paths, '{}'::text[]) loop
    if lower(item) !~ ('^users/' || auth.uid()::text || '/' || folder_name || '/[a-z0-9._/-]+$')
       or item like '%..%' or not exists (
         select 1 from storage.objects o where o.bucket_id = bucket_name and o.name = item
       ) then
      return false;
    end if;
  end loop;
  return true;
end $$;

create or replace function public.set_city_clan_icon(target_clan_id uuid, requested_path text)
returns text language plpgsql security definer set search_path = public, storage, pg_temp as $$
begin
  if not exists(select 1 from public.city_clan_memberships m where m.user_id = auth.uid() and m.clan_id = target_clan_id) then
    raise exception 'not a clan member';
  end if;
  if not public.verify_uploaded_paths(array[requested_path], 'here-public-media', 'clans')
     or lower(requested_path) !~ ('^users/' || auth.uid()::text || '/clans/' || target_clan_id::text || '/[a-z0-9._/-]+$') then
    raise exception 'invalid image upload';
  end if;
  update public.city_clans set icon_path = requested_path where id = target_clan_id;
  return requested_path;
end $$;
