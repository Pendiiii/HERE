-- Keep an active ticket only long enough for the Discord bridge to delete its forum thread.
alter table public.support_tickets drop constraint support_tickets_user_id_fkey;
alter table public.support_tickets alter column user_id drop not null;
alter table public.support_tickets add constraint support_tickets_user_id_fkey
  foreign key (user_id) references public.profiles(id) on delete set null;

create or replace function public.delete_own_account()
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  update public.support_tickets set status = 'closing', updated_at = now()
   where user_id = auth.uid() and status in ('pending', 'open');
  delete from auth.users where id = auth.uid();
  return found;
end $$;

revoke execute on function public.delete_own_account() from public, anon;
grant execute on function public.delete_own_account() to authenticated;

notify pgrst, 'reload schema';
