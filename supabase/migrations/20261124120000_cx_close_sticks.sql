-- A Done / Resolved close stays closed.
-- A re-import of an old message, a duplicate, our own outbound, or a bot/system
-- message does not open it again. Only a customer message that was stored after
-- the close, and that the customer actually sent after the close, opens it.
-- Unsent replies on a closed ticket are cancelled. A marketplace reply that is
-- still queued after 3 days is marked failed once, so it can be closed instead
-- of sitting in the inbox.
-- This migration does not queue or send any customer reply.

alter table public.conversations
  add column if not exists closed_at timestamptz;

comment on column public.conversations.closed_at is
  'When the ticket was marked Resolved. Cleared only when a genuine new customer message arrives after this time.';

update public.conversations
   set closed_at = coalesce(status_changed_at, updated_at, created_at)
 where status = 'resolved'
   and closed_at is null;

create or replace function public.cx_norm_body(p_body text)
returns text
language sql
immutable
set search_path to ''
as $fn$
  select lower(regexp_replace(btrim(coalesce(p_body, '')), '\s+', ' ', 'g'));
$fn$;

create or replace function public.cx_is_bot_or_system(p_author text, p_body text)
returns boolean
language sql
immutable
set search_path to ''
as $fn$
  select coalesce(p_author, '') ~* '(chatbot|auto-reply|\meggsy\M|tiktok system|seller center|\m(system|automated|notification)\M|no-reply|mailer@)'
      or coalesce(p_body, '') ~* '^\[Summary by Eggsy'
      or coalesce(p_body, '') ~* '^Eggsy log:';
$fn$;

create or replace function public.cx_is_genuine_customer(p_direction text, p_author text, p_body text)
returns boolean
language sql
immutable
set search_path to ''
as $fn$
  select p_direction = 'inbound'
     and not public.cx_is_bot_or_system(p_author, p_body)
     and coalesce(p_body, '') !~ '^\[Summary by Eggsy';
$fn$;

comment on function public.cx_is_genuine_customer(text, text, text) is
  'True for a customer inbound. Bot, system, Eggsy, summary and note rows are not customer messages.';

-- True when a customer message stored after the close is still unanswered.
-- Re-imports of an older copy of the same text, and our own sent replies, do not count.
create or replace function public.cx_has_new_customer_since(p_conversation uuid, p_closed_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path to ''
as $fn$
  select exists (
    select 1
      from public.messages m
     where m.conversation_id = p_conversation
       and public.cx_is_genuine_customer(m.direction::text, m.author, m.body)
       and m.created_at > coalesce(p_closed_at, '-infinity'::timestamptz)
       and coalesce(m.platform_sent_at, m.sent_at) > coalesce(p_closed_at, '-infinity'::timestamptz)
       and not exists (
         select 1
           from public.messages older
          where older.conversation_id = m.conversation_id
            and older.id <> m.id
            and older.direction = 'inbound'
            and public.cx_norm_body(older.body) = public.cx_norm_body(m.body)
            and older.created_at <= coalesce(p_closed_at, '-infinity'::timestamptz)
       )
       and not exists (
         select 1
           from public.messages o
          where o.conversation_id = m.conversation_id
            and o.direction = 'outbound'
            and not public.cx_is_internal_outbound(o.author, o.body)
            and o.sent_at >= coalesce(m.platform_sent_at, m.sent_at)
       )
       and not exists (
         select 1
           from public.reply_queue q
          where q.conversation_id = m.conversation_id
            and q.status = 'sent'
            and coalesce(q.sent_at, q.queued_at) >= coalesce(m.platform_sent_at, m.sent_at)
       )
  );
$fn$;

revoke all on function public.cx_norm_body(text) from public, anon;
revoke all on function public.cx_is_bot_or_system(text, text) from public, anon;
revoke all on function public.cx_is_genuine_customer(text, text, text) from public, anon;
revoke all on function public.cx_has_new_customer_since(uuid, timestamptz) from public, anon;
grant execute on function public.cx_norm_body(text) to authenticated, service_role;
grant execute on function public.cx_is_bot_or_system(text, text) to authenticated, service_role;
grant execute on function public.cx_is_genuine_customer(text, text, text) to authenticated, service_role;
grant execute on function public.cx_has_new_customer_since(uuid, timestamptz) to authenticated, service_role;

create or replace function public.conversations_status_stamp()
returns trigger
language plpgsql
set search_path to ''
as $fn$
begin
  if tg_op = 'INSERT' then
    new.status_changed_at := coalesce(new.status_changed_at, now());
    if new.status = 'resolved' then
      new.closed_at := coalesce(new.closed_at, now());
    end if;
  elsif old.status = 'resolved'
        and new.status in ('open', 'awaiting_approval', 'awaiting_customer')
        and not public.cx_has_new_customer_since(old.id, coalesce(old.closed_at, old.status_changed_at)) then
    new.status := old.status;
    new.closed_at := old.closed_at;
  elsif new.status is distinct from old.status then
    new.status_changed_at := now();
    if new.status = 'resolved' then
      new.closed_at := now();
    elsif old.status = 'resolved' then
      new.closed_at := null;
    end if;
  end if;
  return new;
end
$fn$;

create or replace function public.messages_reopen_on_inbound()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  if public.cx_is_genuine_customer(new.direction::text, new.author, new.body)
     and exists (
       select 1
         from public.conversations c
        where c.id = new.conversation_id
          and c.status = 'resolved'
          and public.cx_has_new_customer_since(c.id, coalesce(c.closed_at, c.status_changed_at))
     ) then
    update public.conversations
       set status = 'open',
           updated_at = now()
     where id = new.conversation_id
       and status = 'resolved';
  elsif new.direction = 'inbound'
        and public.cx_is_genuine_customer(new.direction::text, new.author, new.body) then
    update public.conversations c
       set status = 'open',
           updated_at = now()
     where c.id = new.conversation_id
       and c.status = 'awaiting_customer'
       and coalesce(new.platform_sent_at, new.sent_at) > coalesce(c.status_changed_at, '-infinity'::timestamptz)
       and not exists (
         select 1
           from public.messages older
          where older.conversation_id = new.conversation_id
            and older.id <> new.id
            and older.direction = 'inbound'
            and public.cx_norm_body(older.body) = public.cx_norm_body(new.body)
            and older.created_at <= coalesce(c.status_changed_at, '-infinity'::timestamptz)
       )
       and not exists (
         select 1
           from public.messages o
          where o.conversation_id = new.conversation_id
            and o.direction = 'outbound'
            and not public.cx_is_internal_outbound(o.author, o.body)
            and o.sent_at >= coalesce(new.platform_sent_at, new.sent_at)
       );
  end if;
  return new;
end
$fn$;

-- Resolved means the unsent reply is finished with. Cancel it so a later import
-- cannot treat that queue row as "we replied".
create or replace function public.cx_cancel_unsent_on_close()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  if new.status = 'resolved' and old.status is distinct from 'resolved' then
    update public.reply_queue
       set status = 'cancelled',
           cancelled_at = now(),
           cancelled_by = 'close'
     where conversation_id = new.id
       and status in ('queued', 'failed')
       and sent_at is null;
    update public.reply_queue
       set dismissed_at = coalesce(dismissed_at, now()),
           dismissed_by = coalesce(dismissed_by, 'close')
     where conversation_id = new.id
       and status = 'expired'
       and dismissed_at is null;
  end if;
  return null;
end
$fn$;

drop trigger if exists cx_cancel_unsent_on_close on public.conversations;
create trigger cx_cancel_unsent_on_close
  after update of status on public.conversations
  for each row
  execute function public.cx_cancel_unsent_on_close();

revoke all on function public.cx_cancel_unsent_on_close() from public, anon, authenticated;

-- A queued marketplace reply that was never posted is not "we've replied".
-- Email replies stay queued: the hey@ sweep still sends those.
create or replace function public.cx_fail_stale_queued_replies()
returns integer
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  n integer := 0;
  r record;
  note_id text;
begin
  for r in
    select q.id, q.conversation_id, q.queued_at, q.send_error, c.status, c.flag
      from public.reply_queue q
      join public.conversations c on c.id = q.conversation_id
     where q.status = 'queued'
       and q.sent_at is null
       and q.origin::text not in ('email_hey', 'shopify_form', 'wix_mmc_form')
       and (
         q.queued_at < now() - interval '3 days'
         or coalesce(q.send_error, '') ~* 'not found|no chats|timed out|cannot send|lacks messaging|chat not found'
       )
       and c.status not in ('resolved', 'ignored')
  loop
    update public.reply_queue
       set status = 'failed',
           send_error = coalesce(nullif(btrim(send_error), ''),
             'Could not post this reply: the chat was not found, or it was still queued after 3 days. It will not be retried. Close the ticket if nothing else is needed.')
     where id = r.id
       and status = 'queued';
    if not found then
      continue;
    end if;
    n := n + 1;
    if r.flag is null then
      update public.conversations
         set flag = 'Reply not posted: chat not found, or still queued after 3 days. Close the ticket if nothing else is needed.',
             flagged_at = now()
       where id = r.conversation_id
         and flag is null
         and status not in ('resolved', 'ignored');
    end if;
    note_id := 'note:reply-unposted:' || r.id::text;
    insert into public.messages (conversation_id, direction, author, body, sent_at, external_id)
    values (
      r.conversation_id,
      'note',
      'Eggsy',
      'Eggsy log: this queued reply was not posted (chat not found, or still queued after 3 days). It is in Gaps / failed. Close the ticket if nothing else is needed. Nothing was sent to the customer.',
      r.queued_at,
      note_id
    )
    on conflict (conversation_id, external_id) do nothing;
  end loop;
  return n;
end
$fn$;

revoke all on function public.cx_fail_stale_queued_replies() from public, anon, authenticated;
grant execute on function public.cx_fail_stale_queued_replies() to service_role;

create or replace function public.cx_expire_closed_reply_windows()
returns integer
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  n integer := 0;
  r record;
  e record;
  updated integer;
begin
  for r in
    select q.id, q.origin, q.conversation_id, q.send_error, q.message_tag, q.status, q.bounced_at
      from public.reply_queue q
     where q.status in ('queued', 'failed')
  loop
    if r.bounced_at is not null then
      continue;
    end if;
    select * into e
      from public.cx_reply_window_expiry(
        r.origin, r.conversation_id, r.send_error, r.message_tag, r.status
      )
     limit 1;
    if not found then
      continue;
    end if;
    update public.reply_queue
       set status = 'expired',
           expiry_reason = e.reason_code,
           expiry_detail = e.reason_label,
           window_closed_at = e.window_closed_at,
           last_customer_at = e.last_customer_at
     where id = r.id
       and status in ('queued', 'failed');
    get diagnostics updated = row_count;
    n := n + updated;
  end loop;
  n := n + public.cx_fail_stale_queued_replies();
  return n;
end
$fn$;

-- Inbox rows whose latest customer message is more than 5 days old, and that
-- already have a native or Eggsy reply at or after that message. Does not close
-- a ticket whose customer wrote again after our last reply. Does not send anything.
create or replace function public.cx_close_answered_stale(p_apply boolean default false, p_age interval default '5 days')
returns integer
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  n integer := 0;
  r record;
begin
  for r in
    with cust as (
      select m.conversation_id,
             max(coalesce(m.platform_sent_at, m.sent_at)) as last_customer_at
        from public.messages m
       where public.cx_is_genuine_customer(m.direction::text, m.author, m.body)
       group by m.conversation_id
    ),
    rep as (
      select conversation_id, max(replied_at) as replied_at
        from (
          select m.conversation_id, m.sent_at as replied_at
            from public.messages m
           where m.direction = 'outbound'
             and not public.cx_is_internal_outbound(m.author, m.body)
          union all
          select m.conversation_id, coalesce(m.platform_sent_at, m.sent_at)
            from public.messages m
           where m.direction = 'note'
             and m.author ~* '(chatbot|customer service)'
             and m.author !~* 'eggsy'
             and coalesce(m.body, '') !~* '^Eggsy log:'
          union all
          select q.conversation_id, coalesce(q.sent_at, q.queued_at)
            from public.reply_queue q
           where q.status = 'sent'
        ) sent
       group by conversation_id
    )
    select s.conversation_id
      from public.cx_conversation_state s
      join cust cu on cu.conversation_id = s.conversation_id
      join rep rp on rp.conversation_id = s.conversation_id
     where s.bucket = 'inbox'
       and cu.last_customer_at < now() - p_age
       and rp.replied_at >= cu.last_customer_at
       and not exists (
         select 1
           from public.messages m
          where m.conversation_id = s.conversation_id
            and public.cx_is_genuine_customer(m.direction::text, m.author, m.body)
            and coalesce(m.platform_sent_at, m.sent_at) > rp.replied_at
       )
  loop
    n := n + 1;
    if p_apply then
      update public.conversations
         set status = 'resolved',
             updated_at = now()
       where id = r.conversation_id
         and status is distinct from 'resolved'
         and status is distinct from 'ignored';
    end if;
  end loop;
  return n;
end
$fn$;

revoke all on function public.cx_close_answered_stale(boolean, interval) from public, anon, authenticated;
grant execute on function public.cx_close_answered_stale(boolean, interval) to service_role;

comment on function public.cx_close_answered_stale(boolean, interval) is
  'Count (p_apply false) or resolve (p_apply true) inbox tickets whose latest customer message is older than p_age and that already have a native or Eggsy reply after it. Never sends a reply.';

-- Waiting no longer treats a days-old unsent marketplace queue row as a reply.
create or replace view public.cx_conversation_state
with (security_invoker = true) as
with m as (
  select messages.conversation_id,
         max(messages.sent_at) filter (where messages.direction = 'inbound'::public.cx_direction) as last_customer_at,
         max(messages.sent_at) filter (
           where messages.direction = 'outbound'::public.cx_direction
             and not public.cx_is_internal_outbound(messages.author, messages.body)
         ) as last_our_message_at
    from public.messages
   group by messages.conversation_id
),
q as (
  select reply_queue.conversation_id,
         max(coalesce(reply_queue.sent_at, reply_queue.sending_at, reply_queue.queued_at)) as last_queued_at
    from public.reply_queue
   where reply_queue.status = 'sent'::public.cx_send_status
      or reply_queue.status = 'sending'::public.cx_send_status
      or (
        reply_queue.status = 'queued'::public.cx_send_status
        and (
          reply_queue.origin::text in ('email_hey', 'shopify_form', 'wix_mmc_form')
          or reply_queue.queued_at > now() - interval '3 days'
        )
      )
   group by reply_queue.conversation_id
),
s as (
  select c.id as conversation_id,
         c.status,
         c.status_changed_at,
         c.closed_at,
         m.last_customer_at,
         greatest(m.last_our_message_at, q.last_queued_at) as last_reply_at
    from public.conversations c
    left join m on m.conversation_id = c.id
    left join q on q.conversation_id = c.id
   where c.merged_into is null
),
s2 as (
  select s.conversation_id,
         s.status,
         s.status_changed_at,
         s.closed_at,
         s.last_customer_at,
         s.last_reply_at,
         s.status = 'resolved'::public.cx_status
           and not public.cx_has_new_customer_since(s.conversation_id, coalesce(s.closed_at, s.status_changed_at)) as closed
    from s
)
select conversation_id,
       status,
       last_customer_at,
       last_reply_at,
       case
         when status = 'ignored'::public.cx_status then 'junk'::text
         when closed then 'resolved'::text
         when last_reply_at is not null and (last_customer_at is null or last_reply_at >= last_customer_at) then 'waiting'::text
         else 'inbox'::text
       end as bucket,
       case
         when status <> 'ignored'::public.cx_status
          and not closed
          and last_customer_at is not null
          and (last_reply_at is null or last_customer_at > last_reply_at)
         then (
           select min(mm.sent_at)
             from public.messages mm
            where mm.conversation_id = s2.conversation_id
              and mm.direction = 'inbound'::public.cx_direction
              and (s2.last_reply_at is null or mm.sent_at > s2.last_reply_at)
         )
         else null::timestamptz
       end as needs_reply_since
  from s2;

comment on view public.cx_conversation_state is
  'Inbox / Waiting / Resolved. Resolved stays resolved until a genuine new customer message is stored after closed_at and is still unanswered. A marketplace reply queued for more than 3 days does not count as a reply. Merged tickets are omitted.';

-- One-off: unsent rows on tickets already Resolved are finished.
update public.reply_queue q
   set status = 'cancelled',
       cancelled_at = now(),
       cancelled_by = 'close'
  from public.conversations c
 where c.id = q.conversation_id
   and c.status in ('resolved', 'ignored')
   and q.status in ('queued', 'failed')
   and q.sent_at is null;

update public.reply_queue q
   set dismissed_at = coalesce(q.dismissed_at, now()),
       dismissed_by = coalesce(q.dismissed_by, 'close')
  from public.conversations c
 where c.id = q.conversation_id
   and c.status in ('resolved', 'ignored')
   and q.status = 'expired'
   and q.dismissed_at is null;

grant select on public.cx_conversation_state to authenticated;

-- Mark marketplace replies that are already stuck, so open tickets show in Gaps / failed.
do $do$
begin
  perform public.cx_fail_stale_queued_replies();
end
$do$;
