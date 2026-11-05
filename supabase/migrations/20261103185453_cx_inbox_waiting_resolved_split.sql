-- Inbox / Waiting / Resolved split
alter table public.conversations add column if not exists status_changed_at timestamptz;
update public.conversations set status_changed_at = coalesce(updated_at, created_at) where status_changed_at is null;

create or replace function public.conversations_status_stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then new.status_changed_at := coalesce(new.status_changed_at, now());
  elsif new.status is distinct from old.status then new.status_changed_at := now(); end if;
  return new;
end $$;
drop trigger if exists conversations_status_stamp on public.conversations;
create trigger conversations_status_stamp before insert or update of status on public.conversations
  for each row execute function public.conversations_status_stamp();
revoke execute on function public.conversations_status_stamp() from public, anon, authenticated;

-- A message counts as "ours to the customer" unless it is an internal forward/note-like outbound (same rule as the inbox page).
create or replace function public.cx_is_internal_outbound(p_author text, p_body text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_author,'') in ('Marty Pardoe','hey@luckyegg.co') or coalesce(p_body,'') ~* '-{5,} ?Forwarded message'
$$;

create or replace view public.cx_conversation_state with (security_invoker = true) as
with m as (
  select conversation_id,
         max(sent_at) filter (where direction = 'inbound') as last_customer_at,
         max(sent_at) filter (where direction = 'outbound' and not public.cx_is_internal_outbound(author, body)) as last_our_message_at
    from public.messages group by conversation_id),
q as (
  select conversation_id, max(coalesce(sent_at, sending_at, queued_at)) as last_queued_at
    from public.reply_queue where status in ('queued','sending','sent') group by conversation_id),
s as (
  select c.id as conversation_id, c.status, m.last_customer_at,
         greatest(m.last_our_message_at, q.last_queued_at) as last_reply_at
    from public.conversations c left join m on m.conversation_id = c.id left join q on q.conversation_id = c.id)
select s.conversation_id, s.status, s.last_customer_at, s.last_reply_at,
       case when s.status in ('resolved','ignored') then 'resolved'
            when s.last_reply_at is not null and (s.last_customer_at is null or s.last_reply_at >= s.last_customer_at) then 'waiting'
            else 'inbox' end as bucket,
       -- oldest customer message we have not answered yet (Inbox sorts by this, oldest first)
       case when s.status not in ('resolved','ignored') and s.last_customer_at is not null
             and (s.last_reply_at is null or s.last_customer_at > s.last_reply_at)
            then (select min(mm.sent_at) from public.messages mm where mm.conversation_id = s.conversation_id
                   and mm.direction = 'inbound' and (s.last_reply_at is null or mm.sent_at > s.last_reply_at)) end as needs_reply_since
  from s;
revoke all on public.cx_conversation_state from public, anon;
grant select on public.cx_conversation_state to authenticated;
comment on view public.cx_conversation_state is 'Inbox/Waiting/Resolved bucket per conversation. resolved = status resolved or ignored; waiting = our latest reply (outbound message, or reply_queue row queued/sending/sent) is at or after the latest customer message; inbox = everything else. RLS of the underlying tables applies (security_invoker).';

create or replace function public.cx_bucket_counts() returns json
language sql stable set search_path = '' as $$
  select json_build_object(
    'inbox', count(*) filter (where bucket = 'inbox'),
    'waiting', count(*) filter (where bucket = 'waiting'),
    'resolved', count(*) filter (where bucket = 'resolved'))
  from public.cx_conversation_state
$$;
revoke execute on function public.cx_bucket_counts() from public, anon;
grant execute on function public.cx_bucket_counts() to authenticated;

-- A new customer message on a Waiting/Resolved conversation moves it back to Inbox.
-- Guard: only when the message is newer than the last status change, so the routine marking a conversation
-- resolved before inserting the final "thank you" (or backfilling older messages) does not reopen it.
-- Ignored (spam/affiliate) conversations are never reopened.
create or replace function public.messages_reopen_on_inbound() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.direction = 'inbound' then
    update public.conversations c
       set status = 'open', updated_at = now()
     where c.id = new.conversation_id
       and c.status in ('resolved','awaiting_customer')
       and new.sent_at > coalesce(c.status_changed_at, '-infinity'::timestamptz)
       and not exists (select 1 from public.messages o where o.conversation_id = new.conversation_id
                         and o.direction = 'outbound' and o.sent_at >= new.sent_at
                         and not public.cx_is_internal_outbound(o.author, o.body));
  end if;
  return new;
end $$;
drop trigger if exists messages_reopen_on_inbound on public.messages;
create trigger messages_reopen_on_inbound after insert on public.messages
  for each row execute function public.messages_reopen_on_inbound();
revoke execute on function public.messages_reopen_on_inbound() from public, anon, authenticated;
