-- A device owner can remove its anonymous account and all dependent HERE data.
create or replace function public.delete_own_account()
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  delete from auth.users where id = auth.uid();
  return found;
end $$;

revoke execute on function public.delete_own_account() from public, anon;
grant execute on function public.delete_own_account() to authenticated;
