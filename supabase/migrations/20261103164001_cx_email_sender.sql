create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- 1) Which channels may be sent instantly by email from hey@ (config; Walmart / Shopify / plain email OFF)
create table if not exists public.email_send_channels (
  origin public.cx_origin primary key,
  enabled boolean not null default false,
  relay_domain text,          -- buyer relay domain to look up in hey@ (Amazon); null = reply to the stored customer address
  note text,
  updated_at timestamptz not null default now()
);
insert into public.email_send_channels (origin, enabled, relay_domain, note) values
 ('amazon_uk', true,  'marketplace.amazon.co.uk', 'Reply to the buyer relay address from hey@; lands in the Seller Central thread'),
 ('amazon_us', true,  'marketplace.amazon.com',   'Reply to the buyer relay address from hey@; lands in the Seller Central thread'),
 ('walmart',   false, null, 'Not configured on Walmart yet'),
 ('shopify_form', false, null, 'Reply to the customer email (not mailer@shopify.com); off until tested'),
 ('email_hey', false, null, 'Plain hey@ email; still sent by Eggsy at its checks'),
 ('wix_mmc_form', false, null, 'New email to the customer; still sent by Eggsy at its checks')
on conflict (origin) do nothing;
alter table public.email_send_channels enable row level security;
alter table public.email_send_channels force row level security;
revoke all on public.email_send_channels from anon, authenticated;
grant select on public.email_send_channels to authenticated;
drop policy if exists "staff read email channels" on public.email_send_channels;
create policy "staff read email channels" on public.email_send_channels for select to authenticated using ((select public.is_lucky_egg_staff()));

-- 2) reply_queue: email send details
alter table public.reply_queue
  add column if not exists send_route text,              -- 'email' when sent by the Gmail API sender
  add column if not exists email_subject text,
  add column if not exists email_in_reply_to text,        -- RFC Message-ID of the buyer email we answered
  add column if not exists email_message_id text,         -- RFC Message-ID of our sent email
  add column if not exists gmail_sent_id text,
  add column if not exists gmail_sent_thread_id text,
  add column if not exists email_attempted_at timestamptz,
  add column if not exists email_note text,               -- why it could not go by email (left for Eggsy's check)
  add column if not exists bounced_at timestamptz,
  add column if not exists bounce_gmail_id text;
create index if not exists reply_queue_email_sent_idx on public.reply_queue (sent_at) where send_route = 'email';

-- App users may only supply conversation_id and body (everything else is filled by trigger)
revoke insert on public.reply_queue from authenticated;
grant insert (conversation_id, body) on public.reply_queue to authenticated;

-- 3) Visible ticket flag
alter table public.conversations
  add column if not exists flag text,
  add column if not exists flagged_at timestamptz;

-- 4) Sent log: delivery failures
alter table public.sent_log
  add column if not exists delivery_failed_at timestamptz,
  add column if not exists failure_reason text;

-- 5) Bounce emails already processed
create table if not exists public.email_bounce_seen (
  gmail_id text primary key,
  reply_queue_id uuid references public.reply_queue(id) on delete set null,
  seen_at timestamptz not null default now()
);
alter table public.email_bounce_seen enable row level security;
alter table public.email_bounce_seen force row level security;
revoke all on public.email_bounce_seen from anon, authenticated;

-- 6) Shared secret between the database and the edge function (kept in Vault)
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'eggsy_email_hook_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'eggsy_email_hook_secret', 'Auth header for send-email-reply');
  end if;
end $$;

create or replace function public.cx_email_hook_ok(p_secret text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select decrypted_secret = p_secret from vault.decrypted_secrets where name = 'eggsy_email_hook_secret'), false) $$;
revoke all on function public.cx_email_hook_ok(text) from public, anon, authenticated;
grant execute on function public.cx_email_hook_ok(text) to service_role;

create or replace function public.cx_email_call(p_payload jsonb) returns bigint
language plpgsql security definer set search_path = '' as $$
declare s text; rid bigint;
begin
  select decrypted_secret into s from vault.decrypted_secrets where name = 'eggsy_email_hook_secret';
  select net.http_post(
    url := 'https://xodkbmtylftfmnxfnxxf.supabase.co/functions/v1/send-email-reply',
    body := p_payload,
    headers := jsonb_build_object('Content-Type','application/json','x-eggsy-hook', s),
    timeout_milliseconds := 60000) into rid;
  return rid;
end $$;
revoke all on function public.cx_email_call(jsonb) from public, anon, authenticated;

-- 7) Instant trigger: a newly queued reply on an enabled email channel calls the sender
create or replace function public.reply_queue_email_kick() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'queued' and exists (select 1 from public.email_send_channels e where e.origin = new.origin and e.enabled) then
    perform public.cx_email_call(jsonb_build_object('mode','send','reply_id', new.id));
  end if;
  return null;
end $$;
revoke all on function public.reply_queue_email_kick() from public, anon, authenticated;
drop trigger if exists reply_queue_email_kick on public.reply_queue;
create trigger reply_queue_email_kick after insert on public.reply_queue for each row execute function public.reply_queue_email_kick();

-- 8) Mark an email reply sent (README step 3a, plus thread id/language) and retire the suggestion
create or replace function public.cx_email_mark_sent(p_reply_id uuid, p_gmail_id text, p_thread_id text, p_message_id_hdr text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r record; mid uuid; lang text; ben text;
begin
  select * into r from public.reply_queue where id = p_reply_id and status = 'sending' for update;
  if not found then return null; end if;
  select d.language, d.body_en into lang, ben from public.suggested_drafts d
   where d.conversation_id = r.conversation_id and btrim(d.body) = btrim(r.body) order by d.drafted_at desc limit 1;
  if lang is null then
    select m.language into lang from public.messages m where m.conversation_id = r.conversation_id and m.direction = 'inbound' and m.language is not null order by m.sent_at desc limit 1;
    if lang is distinct from 'en' then lang := null; end if;  -- only claim English when we know; no translation invented
  end if;
  insert into public.messages (conversation_id, direction, author, body, sent_at, external_id, external_thread_id, language, body_en)
  values (r.conversation_id, 'outbound', 'The Lucky Egg Team (queued by ' || coalesce(r.queued_by, 'Eggsy CX') || ')',
          r.body, now(), 'gmail:' || p_gmail_id, p_thread_id, lang, case when lang = 'en' then null else ben end)
  on conflict (conversation_id, external_id) do update set body = excluded.body
  returning id into mid;
  update public.reply_queue
     set status = 'sent', sent_at = now(), sent_external_id = 'gmail:' || p_gmail_id, message_id = mid, send_error = null,
         send_route = 'email', gmail_sent_id = p_gmail_id, gmail_sent_thread_id = p_thread_id, email_message_id = p_message_id_hdr
   where id = p_reply_id;      -- trigger reply_queue_log_sent writes the sent_log row (route 'queued in Eggsy CX')
  update public.conversations set status = 'awaiting_customer', updated_at = now() where id = r.conversation_id;
  update public.suggested_drafts set superseded = true, superseded_at = now() where conversation_id = r.conversation_id and not superseded;
  return mid;
end $$;
revoke all on function public.cx_email_mark_sent(uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.cx_email_mark_sent(uuid,text,text,text) to service_role;

-- 9) A delivery failure: reply failed, sent log marked, ticket flagged and reopened, Eggsy log note
create or replace function public.cx_email_mark_bounced(p_reply_id uuid, p_bounce_gmail_id text, p_reason text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  insert into public.email_bounce_seen (gmail_id, reply_queue_id) values (p_bounce_gmail_id, p_reply_id) on conflict do nothing;
  select * into r from public.reply_queue where id = p_reply_id and status = 'sent' and bounced_at is null for update;
  if not found then return false; end if;
  update public.reply_queue set status = 'failed', bounced_at = now(), bounce_gmail_id = p_bounce_gmail_id,
         send_error = 'Not delivered: ' || p_reason || ' The buyer has NOT received this reply. Post it in Seller Central or edit and send again.'
   where id = p_reply_id;
  update public.sent_log set delivery_failed_at = now(), failure_reason = p_reason where reply_queue_id = p_reply_id;
  update public.conversations set flag = 'Reply not delivered: ' || p_reason, flagged_at = now(), status = 'open', updated_at = now()
   where id = r.conversation_id;
  insert into public.messages (conversation_id, direction, author, body, sent_at, external_id, language)
  values (r.conversation_id, 'note', 'Eggsy', 'Eggsy log: the reply sent by email at ' ||
          to_char(r.sent_at at time zone 'Europe/London', 'DD Mon HH24:MI') || ' UK time was NOT delivered (' || p_reason || '). It needs posting again.',
          now(), 'note:bounce:' || p_reply_id, 'en')
  on conflict (conversation_id, external_id) do nothing;
  return true;
end $$;
revoke all on function public.cx_email_mark_bounced(uuid,text,text) from public, anon, authenticated;
grant execute on function public.cx_email_mark_bounced(uuid,text,text) to service_role;

-- service role needs table access for the function (it bypasses RLS)
grant select, insert, update on public.email_bounce_seen, public.email_send_channels to service_role;

-- 10) Safety-net sweep + delivery-failure check every 3 minutes
select cron.unschedule(jobid) from cron.job where jobname = 'eggsy-email-sweep';
select cron.schedule('eggsy-email-sweep', '*/3 * * * *', $c$select public.cx_email_call('{"mode":"sweep"}'::jsonb)$c$);
