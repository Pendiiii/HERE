create or replace function public.get_my_display_name()
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select display_name from public.profiles where id = auth.uid();
$$;

revoke execute on function public.get_my_display_name() from public, anon;
grant execute on function public.get_my_display_name() to authenticated;
