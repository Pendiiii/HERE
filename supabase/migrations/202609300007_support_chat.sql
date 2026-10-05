create type public.support_ticket_status as enum ('pending', 'open', 'closing', 'closed');
create type public.support_sender as enum ('user', 'staff', 'system');

create table public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  status public.support_ticket_status not null default 'pending',
  discord_thread_id text unique,
  assigned_staff_id text,
  assigned_staff_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz
);

create unique index support_tickets_one_active_per_user
  on public.support_tickets(user_id) where status in ('pending', 'open', 'closing');
create index support_tickets_bridge_queue on public.support_tickets(status, updated_at);

create table public.support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  sender public.support_sender not null,
  body text not null check (char_length(body) between 1 and 1500),
  staff_discord_id text,
  staff_display_name text,
  discord_message_id text unique,
  created_at timestamptz not null default now()
);

create index support_messages_ticket_time on public.support_messages(ticket_id, created_at);

alter table public.support_tickets enable row level security;
alter table public.support_messages enable row level security;

create or replace function public.open_support_ticket(first_message text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare clean_body text := trim(first_message); v_ticket_id uuid; recent_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if char_length(clean_body) not between 1 and 1500 then raise exception 'invalid support message'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':support', 0));

  select id into v_ticket_id from public.support_tickets
   where user_id = auth.uid() and status in ('pending', 'open') order by created_at desc limit 1;

  if v_ticket_id is null then
    insert into public.support_tickets(user_id) values(auth.uid()) returning id into v_ticket_id;
  end if;

  select count(*) into recent_count from public.support_messages m
   join public.support_tickets t on t.id = m.ticket_id
   where t.user_id = auth.uid() and m.sender = 'user' and m.created_at > now() - interval '1 minute';
  if recent_count >= 8 then raise exception 'support rate limit exceeded'; end if;

  insert into public.support_messages(ticket_id, sender, body) values(v_ticket_id, 'user', clean_body);
  update public.support_tickets set updated_at = now() where id = v_ticket_id;
  return v_ticket_id;
end $$;

create or replace function public.send_support_message(target_ticket_id uuid, message_text text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare clean_body text := trim(message_text); message_id uuid; recent_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if char_length(clean_body) not between 1 and 1500 then raise exception 'invalid support message'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_ticket_id::text || ':support-message', 0));
  if not exists(select 1 from public.support_tickets where id = target_ticket_id and user_id = auth.uid() and status in ('pending', 'open')) then
    raise exception 'support ticket unavailable';
  end if;
  select count(*) into recent_count from public.support_messages
   where ticket_id = target_ticket_id and sender = 'user' and created_at > now() - interval '1 minute';
  if recent_count >= 8 then raise exception 'support rate limit exceeded'; end if;
  insert into public.support_messages(ticket_id, sender, body)
    values(target_ticket_id, 'user', clean_body) returning id into message_id;
  update public.support_tickets set updated_at = now() where id = target_ticket_id;
  return message_id;
end $$;

create or replace function public.get_support_ticket()
returns table (
  ticket_id uuid, ticket_status text, assigned_staff_name text, ticket_created_at timestamptz,
  message_id uuid, message_sender text, message_body text, message_staff_name text, message_created_at timestamptz
) language sql stable security definer set search_path = public, pg_temp as $$
  with selected as (
    select t.* from public.support_tickets t where t.user_id = auth.uid()
    order by case when t.status in ('pending', 'open', 'closing') then 0 else 1 end, t.created_at desc limit 1
  )
  select t.id, t.status::text, t.assigned_staff_name, t.created_at,
         m.id, m.sender::text, m.body, m.staff_display_name, m.created_at
    from selected t left join public.support_messages m on m.ticket_id = t.id
   order by m.created_at, m.id;
$$;

create or replace function public.close_support_ticket(target_ticket_id uuid)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  update public.support_tickets set status = 'closing', updated_at = now()
   where id = target_ticket_id and user_id = auth.uid() and status in ('pending', 'open');
  return found;
end $$;

revoke all on public.support_tickets, public.support_messages from anon, authenticated;
revoke execute on function public.open_support_ticket(text) from public, anon;
revoke execute on function public.send_support_message(uuid,text) from public, anon;
revoke execute on function public.get_support_ticket() from public, anon;
revoke execute on function public.close_support_ticket(uuid) from public, anon;
grant execute on function public.open_support_ticket(text) to authenticated;
grant execute on function public.send_support_message(uuid,text) to authenticated;
grant execute on function public.get_support_ticket() to authenticated;
grant execute on function public.close_support_ticket(uuid) to authenticated;

notify pgrst, 'reload schema';
