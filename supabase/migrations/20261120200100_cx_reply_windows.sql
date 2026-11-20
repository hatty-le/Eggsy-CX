-- Expired replies: a platform reply window has closed, so the send queue must
-- not keep them and Ready auto-send must not try to send them.
--
-- What counts today
-- * Meta Messenger / Instagram DM, standard send (no message tag): 24 hours
--   after the customer's last real inbound message. Proven by Meta error
--   subcode 2018278 ("outside the allowed 24h window") and, proactively, by
--   the age of that inbound message.
-- * The same channels with message_tag = human_agent: 7 days. Meta's
--   human_agent tag allows that only when the app has the permission. Nothing
--   in this database, and no sender in this repo, sets message_tag. The live
--   failures are subcode 2018278, which is the standard 24-hour window, so
--   the 7-day rule does not apply to current rows. A later sender can record
--   the tag on reply_queue.message_tag and the longer window is used.
--
-- What does not count
-- * Bounced email, "recipient not available", and missing permissions stay
--   failed. An exclusion wins even if the last inbound message is also old.
-- * Amazon's "reply within 24 hours" line in the inbox is a response-time
--   target. Seller Central can still accept a later buyer-seller message, and
--   no send error here means Amazon refused because a window closed. No
--   Amazon rule is installed. Add a row to cx_reply_window_rules for a future
--   hard window.
--
-- cx_log_sent_reply and reply_queue_log_sent are not changed. Expired is not
-- a successful send, so nothing is written to sent_log.

alter table public.reply_queue
  add column if not exists expiry_reason text,
  add column if not exists expiry_detail text,
  add column if not exists window_closed_at timestamptz,
  add column if not exists last_customer_at timestamptz,
  add column if not exists dismissed_at timestamptz,
  add column if not exists dismissed_by text,
  add column if not exists message_tag text;

comment on column public.reply_queue.expiry_reason is
  'Code from cx_reply_window_rules when status is expired. Further reasons are new rules, not new columns.';
comment on column public.reply_queue.expiry_detail is
  'One sentence shown on the Expired page.';
comment on column public.reply_queue.window_closed_at is
  'When the platform stopped accepting this reply. Last customer message plus the rule''s window, or the time we learned the platform had already refused.';
comment on column public.reply_queue.last_customer_at is
  'Customer''s last real inbound message at the time the reply was marked expired. Summaries are ignored.';
comment on column public.reply_queue.dismissed_at is
  'Set when someone archives the row off the Expired page. The status stays expired so it is not sent.';
comment on column public.reply_queue.message_tag is
  'Tag the sender attached, lower-case. Null is a standard send. human_agent selects the 7-day Meta rule. The current sender does not set this.';

grant select (
  expiry_reason, expiry_detail, window_closed_at, last_customer_at,
  dismissed_at, dismissed_by, message_tag
) on public.reply_queue to authenticated;

grant select (expiry_reason, expiry_detail, window_closed_at, last_customer_at, dismissed_at, dismissed_by, message_tag),
      insert (expiry_reason, expiry_detail, window_closed_at, last_customer_at, dismissed_at, dismissed_by, message_tag),
      update (expiry_reason, expiry_detail, window_closed_at, last_customer_at, dismissed_at, dismissed_by, message_tag)
  on public.reply_queue to service_role;

create index if not exists reply_queue_expired_open_idx
  on public.reply_queue (window_closed_at desc)
  where status = 'expired' and dismissed_at is null;

-- Staff inserts are checked after the before-insert triggers. A closed window
-- rewrites status to expired, so that final status has to be allowed or the
-- insert is rejected and the reply never appears on the Expired page.
drop policy if exists "staff queue replies" on public.reply_queue;
create policy "staff queue replies"
  on public.reply_queue
  for insert
  to authenticated
  with check (
    (select public.is_lucky_egg_staff())
    and status in ('queued'::public.cx_send_status, 'expired'::public.cx_send_status)
  );

create table if not exists public.cx_reply_window_rules (
  code text primary key,
  label text not null,
  detail text not null,
  origins text[] not null,
  window_hours integer not null check (window_hours > 0),
  message_tag text,
  dm_only boolean not null default true,
  enabled boolean not null default true,
  error_patterns text[] not null default '{}'::text[]
);

comment on table public.cx_reply_window_rules is
  'Hard platform reply windows. A queued or failed reply expires when its origin matches an enabled rule and either the send error matches error_patterns or the customer''s last inbound message is older than window_hours. message_tag null means a standard send. Add a row to cover another platform. Amazon is intentionally absent: the inbox 24-hour line is a response-time target, not a hard block.';

alter table public.cx_reply_window_rules enable row level security;
revoke all on public.cx_reply_window_rules from public, anon, authenticated;

insert into public.cx_reply_window_rules
  (code, label, detail, origins, window_hours, message_tag, dm_only, error_patterns)
values
  (
    'meta_standard_24h',
    'Meta 24-hour window',
    $detail$Facebook Messenger and Instagram DMs can only be answered within 24 hours of the customer’s last message. The sender does not attach Meta’s human_agent tag, so the 7-day tag does not apply.$detail$,
    array['facebook', 'instagram'],
    24,
    null,
    true,
    array['2018278', '24h window', '24-hour', '24 hour', 'outside the allowed', 'outside allowed']
  ),
  (
    'meta_human_agent_7d',
    'Meta human agent window',
    $detail$Meta’s human_agent tag allows a person to reply for 7 days after the customer’s last message, and only if Meta has approved it for the app. Used only when the reply’s message tag is human_agent.$detail$,
    array['facebook', 'instagram'],
    168,
    'human_agent',
    true,
    array['2018278', 'outside the allowed', 'outside allowed', '7-day', '7 day']
  )
on conflict (code) do update
  set label = excluded.label,
      detail = excluded.detail,
      origins = excluded.origins,
      window_hours = excluded.window_hours,
      message_tag = excluded.message_tag,
      dm_only = excluded.dm_only,
      enabled = excluded.enabled,
      error_patterns = excluded.error_patterns;

-- Bounces, "this person isn't available", and missing permissions are not
-- expired, even when the last inbound message is also older than the window.
create or replace function public.cx_reply_failure_excluded(p_error text)
returns boolean
language sql
immutable
set search_path to ''
as $function$
  select coalesce(p_error, '') ~* (
    'recipient not available'
    || '|isn''t available'
    || '|is not available'
    || '|not available right now'
    || '|not available at the moment'
    || '|1893047'
    || '|messaging permission'
    || '|lacks [^.]{0,80}permission'
    || '|missing permission'
    || '|not delivered:'
    || '|delivery status notification'
    || '|delivery failure'
  );
$function$;

comment on function public.cx_reply_failure_excluded(text) is
  'True when a failed send must stay failed: bounce, recipient not available, or missing permission.';

create or replace function public.cx_reply_window_expiry(
  p_origin public.cx_origin,
  p_conversation uuid,
  p_send_error text,
  p_message_tag text,
  p_status public.cx_send_status
)
returns table (
  reason_code text,
  reason_label text,
  window_closed_at timestamptz,
  last_customer_at timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  last_in timestamptz;
  conv_ext text;
  rule record;
  tag text := nullif(lower(btrim(coalesce(p_message_tag, ''))), '');
  err text := coalesce(p_send_error, '');
  st public.cx_send_status := coalesce(p_status, 'queued');
  error_hit boolean;
  age_hit boolean;
  closed timestamptz;
begin
  if st not in ('queued', 'failed') then
    return;
  end if;
  if public.cx_reply_failure_excluded(err) then
    return;
  end if;

  select c.external_id into conv_ext
    from public.conversations c
   where c.id = p_conversation;

  select max(m.sent_at) into last_in
    from public.messages m
   where m.conversation_id = p_conversation
     and m.direction = 'inbound'
     and coalesce(m.body, '') !~ '^\[Summary by Eggsy';

  for rule in
    select r.code, r.detail, r.window_hours, r.dm_only, r.error_patterns
      from public.cx_reply_window_rules r
     where r.enabled
       and p_origin::text = any (r.origins)
       and r.message_tag is not distinct from tag
     order by r.window_hours
  loop
    error_hit := err <> '' and exists (
      select 1
        from unnest(rule.error_patterns) as pat(pattern)
       where err ~* pat.pattern
    );
    age_hit := last_in is not null
      and last_in + make_interval(hours => rule.window_hours) <= pg_catalog.now();
    -- The proactive clock is the DM window. A public comment uses a different
    -- Meta rule that is not defined here, unless the platform already refused
    -- the send with a window error.
    if rule.dm_only and public.cx_is_meta_public_comment(p_origin, conv_ext) then
      age_hit := false;
    end if;
    if error_hit or age_hit then
      closed := pg_catalog.now();
      if last_in is not null then
        closed := last_in + make_interval(hours => rule.window_hours);
        if closed > pg_catalog.now() then
          closed := pg_catalog.now();
        end if;
      end if;
      reason_code := rule.code;
      reason_label := rule.detail;
      window_closed_at := closed;
      last_customer_at := last_in;
      return next;
      return;
    end if;
  end loop;
end
$function$;

comment on function public.cx_reply_window_expiry(public.cx_origin, uuid, text, text, public.cx_send_status) is
  'One row when a queued or failed reply can no longer be delivered. Empty when the failure is a bounce, an unavailable recipient, a missing permission, or the window is still open.';

revoke all on function public.cx_reply_failure_excluded(text) from public, anon, authenticated;
revoke all on function public.cx_reply_window_expiry(public.cx_origin, uuid, text, text, public.cx_send_status) from public, anon, authenticated;

-- Read-only check used by Ready auto-send and by the ticket composer.
-- Null means a new standard send is still inside the window.
create or replace function public.cx_reply_window_block(p_conversation uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $function$
  select e.reason_code
    from public.conversations c
    cross join lateral public.cx_reply_window_expiry(
      c.origin, c.id, null, null, 'queued'::public.cx_send_status
    ) e
   where c.id = p_conversation
   limit 1;
$function$;

comment on function public.cx_reply_window_block(uuid) is
  'Reason code when a new standard reply on this ticket can no longer be delivered. Null when it still can. Does not write and does not send.';

revoke all on function public.cx_reply_window_block(uuid) from public, anon;
grant execute on function public.cx_reply_window_block(uuid) to authenticated, service_role;

create or replace function public.reply_queue_expire_window()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  e record;
begin
  if new.status in ('sent', 'cancelled', 'expired', 'sending') then
    return new;
  end if;
  if new.bounced_at is not null then
    return new;
  end if;
  if new.status not in ('queued', 'failed') then
    return new;
  end if;

  select * into e
    from public.cx_reply_window_expiry(
      new.origin, new.conversation_id, new.send_error, new.message_tag, new.status
    )
   limit 1;
  if not found then
    return new;
  end if;

  new.status := 'expired';
  new.expiry_reason := e.reason_code;
  new.expiry_detail := e.reason_label;
  new.window_closed_at := e.window_closed_at;
  new.last_customer_at := e.last_customer_at;
  return new;
end
$function$;

drop trigger if exists reply_queue_expire_window on public.reply_queue;
create trigger reply_queue_expire_window
  before insert or update on public.reply_queue
  for each row execute function public.reply_queue_expire_window();

comment on function public.reply_queue_expire_window() is
  'Moves a queued or failed reply to expired when a hard reply window has closed, before email or the marketplace webhook can send it.';

revoke all on function public.reply_queue_expire_window() from public, anon, authenticated;

create or replace function public.cx_expire_closed_reply_windows()
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
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
  return n;
end
$function$;

comment on function public.cx_expire_closed_reply_windows() is
  'Marks queued and failed replies expired once their platform window has closed. Does not send anything.';

revoke all on function public.cx_expire_closed_reply_windows() from public, anon, authenticated;
grant execute on function public.cx_expire_closed_reply_windows() to service_role;

create or replace function public.cx_dismiss_expired_reply(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  n integer;
begin
  if not public.is_lucky_egg_staff() then
    raise exception 'not allowed';
  end if;
  update public.reply_queue
     set dismissed_at = pg_catalog.now(),
         dismissed_by = lower(coalesce((select auth.jwt()) ->> 'email', ''))
   where id = p_id
     and status = 'expired'
     and dismissed_at is null;
  get diagnostics n = row_count;
  return n > 0;
end
$function$;

comment on function public.cx_dismiss_expired_reply(uuid) is
  'Archives one expired reply off the Expired page. Staff only. Status stays expired so it cannot be sent.';

revoke all on function public.cx_dismiss_expired_reply(uuid) from public, anon;
grant execute on function public.cx_dismiss_expired_reply(uuid) to authenticated;

-- Send-queue badge: queued and sending only, so expired rows are not counted.
-- Expired badge: rows still on the Expired page.
create or replace function public.cx_bucket_counts()
returns json
language sql
stable
set search_path to ''
as $function$
  select json_build_object(
    'inbox', count(*) filter (where bucket = 'inbox'),
    'waiting', count(*) filter (where bucket = 'waiting'),
    'resolved', count(*) filter (where bucket = 'resolved'),
    'junk', count(*) filter (where bucket = 'junk'),
    'actions', (select count(*) from public.cx_followups where status = 'open')
      + (select count(*) from public.cx_actions where type = 'follow_up' and status in ('pending', 'created')),
    'queue', (select count(*) from public.reply_queue where status in ('queued', 'sending')),
    'expired', (select count(*) from public.reply_queue where status = 'expired' and dismissed_at is null)
  )
  from public.cx_conversation_state
$function$;

-- Ready auto-send: refuse before insert. The existing functions are replaced
-- in place so every other hold stays as it is. These statements do not call
-- cx_auto_send_ready, cx_queue_ready_draft, or cx_auto_send_preview.
do $patch$
declare
  src text;
  queue_needle text := $needle$insert into public.reply_queue (conversation_id, body, queued_by, requires_action, auto_sent)
                values (p_conversation, r.body, 'eggsy-auto', false, true);
                result := 'queued';$needle$;
  queue_repl text := $repl$if public.cx_reply_window_block(p_conversation) is not null then
                  result := 'reply_window_expired';
                else
                  insert into public.reply_queue (conversation_id, body, queued_by, requires_action, auto_sent)
                  values (p_conversation, r.body, 'eggsy-auto', false, true);
                  result := 'queued';
                end if;$repl$;
  preview_needle text := $needle$IF public.cx_has_placeholder(p_body) THEN RETURN 'not_ready'; END IF;
  RETURN 'queued';$needle$;
  preview_repl text := $repl$IF public.cx_has_placeholder(p_body) THEN RETURN 'not_ready'; END IF;
  IF public.cx_reply_window_block(p_conversation) IS NOT NULL THEN RETURN 'reply_window_expired'; END IF;
  RETURN 'queued';$repl$;
begin
  src := pg_get_functiondef('public.cx_queue_ready_draft(uuid)'::regprocedure);
  if strpos(src, 'reply_window_expired') = 0 then
    if strpos(src, queue_needle) = 0 then
      raise exception 'cx_queue_ready_draft insert block not found; auto-send window guard was not applied';
    end if;
    src := replace(src, queue_needle, queue_repl);
    execute src;
  end if;

  src := pg_get_functiondef('public.cx_auto_send_preview(uuid,text,integer)'::regprocedure);
  if strpos(src, 'reply_window_expired') = 0 then
    if strpos(src, preview_needle) = 0 then
      raise exception 'cx_auto_send_preview return block not found; auto-send window guard was not applied';
    end if;
    src := replace(src, preview_needle, preview_repl);
    execute src;
  end if;
end
$patch$;

do $cron$
begin
  if exists (select 1 from cron.job where jobname = 'cx-expire-reply-windows') then
    perform cron.unschedule('cx-expire-reply-windows');
  end if;
  perform cron.schedule(
    'cx-expire-reply-windows',
    '*/15 * * * *',
    $job$select public.cx_expire_closed_reply_windows()$job$
  );
end
$cron$;

-- Move rows that already qualify. Does not send.
select public.cx_expire_closed_reply_windows();

do $check$
begin
  if (select status from public.reply_queue where id = '93a9327e-abf8-4c81-a12c-2aac650dd2a9')
     is distinct from 'expired'::public.cx_send_status then
    raise exception '93a9327e was not moved to expired';
  end if;
  if (select status from public.reply_queue where id = 'f0e7246a-7b51-4073-98e4-1a4efa08bbc1')
     is distinct from 'expired'::public.cx_send_status then
    raise exception 'f0e7246a was not moved to expired';
  end if;
  if (select expiry_reason from public.reply_queue where id = 'f0e7246a-7b51-4073-98e4-1a4efa08bbc1')
     is distinct from 'meta_standard_24h' then
    raise exception 'f0e7246a expiry reason was not the Meta 24-hour window';
  end if;
  if exists (
    select 1 from public.reply_queue
     where status = 'expired'
       and public.cx_reply_failure_excluded(send_error)
  ) then
    raise exception 'a bounce, unavailable recipient, or permission failure was marked expired';
  end if;
  if (select status from public.reply_queue where id = '45e68d69-30d3-4c36-b3ee-a8338fc8b9e6')
     is distinct from 'queued'::public.cx_send_status then
    raise exception 'the in-window Instagram reply was taken out of the send queue';
  end if;
  if public.cx_reply_window_block('c8c677a6-500c-45de-b782-0136ff73107b')
     is distinct from 'meta_standard_24h' then
    raise exception 'auto-send would not refuse the closed Meta thread';
  end if;
  if public.cx_reply_window_block('56690d05-647c-4a4c-87c5-45980b775242') is null
     and (select status from public.reply_queue where id = '45e68d69-30d3-4c36-b3ee-a8338fc8b9e6')
         is distinct from 'queued'::public.cx_send_status then
    raise exception 'an Instagram reply still inside 24 hours was taken out of the send queue';
  end if;
end
$check$;
