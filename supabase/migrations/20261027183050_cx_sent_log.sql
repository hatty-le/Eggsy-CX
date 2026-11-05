create or replace function public.cx_channel_label(o public.cx_origin) returns text language sql immutable set search_path to '' as $$
 select case o::text
  when 'email_hey' then 'Email (hey@)' when 'shopify_form' then 'Shopify form (email)' when 'wix_mmc_form' then 'MMC Wix form (email)'
  when 'tiktok_uk' then 'TikTok UK' when 'tiktok_eu' then 'TikTok EU' when 'tiktok_us' then 'TikTok US'
  when 'amazon_other' then 'Amazon (other)' when 'walmart' then 'Walmart' when 'facebook' then 'Facebook' when 'instagram' then 'Instagram'
  else case when o::text like 'amazon\_%' then 'Amazon '||upper(substr(o::text,8)) else o::text end end $$;

create table public.sent_log (
  id uuid primary key default gen_random_uuid(),
  sent_at timestamptz not null default now(),
  conversation_id uuid references public.conversations(id) on delete set null,
  message_id uuid references public.messages(id) on delete set null,
  reply_queue_id uuid unique references public.reply_queue(id) on delete set null,
  origin public.cx_origin,
  shop text, customer_name text, customer_handle text, order_number text,
  channel text,
  body text not null,
  route text not null check (route in ('queued in Eggsy CX','approved in chat','email card')),
  approved_by text,
  sent_by text not null default 'Eggsy',
  external_id text,
  created_at timestamptz not null default now()
);
create unique index sent_log_external_id_key on public.sent_log (external_id) where external_id is not null;
create index sent_log_sent_at_idx on public.sent_log (sent_at desc);
create index sent_log_conversation_idx on public.sent_log (conversation_id);
create index sent_log_message_idx on public.sent_log (message_id);

-- snapshot conversation details at insert time so entries survive conversation deletion
create or replace function public.sent_log_before_insert() returns trigger language plpgsql set search_path to '' as $$
declare c record;
begin
  if new.conversation_id is not null then
    select origin, shop, customer_name, customer_handle, order_number into c from public.conversations where id = new.conversation_id;
    if found then
      new.origin := coalesce(new.origin, c.origin); new.shop := coalesce(new.shop, c.shop);
      new.customer_name := coalesce(new.customer_name, c.customer_name); new.customer_handle := coalesce(new.customer_handle, c.customer_handle);
      new.order_number := coalesce(new.order_number, c.order_number);
    end if;
  end if;
  if new.channel is null and new.origin is not null then new.channel := public.cx_channel_label(new.origin); end if;
  return new;
end $$;
create trigger sent_log_before_insert before insert on public.sent_log for each row execute function public.sent_log_before_insert();

-- every reply_queue row that becomes 'sent' is logged automatically
create or replace function public.reply_queue_log_sent() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.status = 'sent' and (tg_op = 'INSERT' or old.status is distinct from 'sent') then
    insert into public.sent_log (sent_at, conversation_id, message_id, reply_queue_id, origin, shop, body, route, approved_by, external_id)
    values (coalesce(new.sent_at, now()), new.conversation_id, new.message_id, new.id, new.origin, new.shop, new.body,
            'queued in Eggsy CX', new.queued_by, coalesce(new.sent_external_id, 'reply:' || new.id))
    on conflict do nothing;
  end if;
  return null;
end $$;
create trigger reply_queue_log_sent after insert or update of status on public.reply_queue for each row execute function public.reply_queue_log_sent();

alter table public.sent_log enable row level security;
alter table public.sent_log force row level security;
create policy "staff read sent_log" on public.sent_log for select to authenticated using ((select public.is_lucky_egg_staff()));
revoke all on public.sent_log from anon, authenticated;
grant select on public.sent_log to authenticated;

-- logging helper for chat-approved and email-card sends (connector/service role only)
create or replace function public.cx_log_sent_reply(
  p_origin public.cx_origin, p_body text, p_route text,
  p_sent_at timestamptz default now(), p_conversation_id uuid default null, p_conv_external_id text default null,
  p_order_number text default null, p_customer_name text default null, p_customer_handle text default null,
  p_shop text default null, p_subject text default null, p_external_id text default null,
  p_approved_by text default 'hatty@luckyegg.co', p_author text default 'The Lucky Egg Team (sent by Eggsy)')
returns uuid language plpgsql set search_path to '' as $$
declare cid uuid; mid uuid; lid uuid; ext text;
begin
  if p_route not in ('approved in chat','email card') then raise exception 'route must be approved in chat or email card'; end if;
  if coalesce(btrim(p_body),'') = '' then raise exception 'body is empty'; end if;
  -- 1) find the conversation: id, then origin+external_id, then origin+order, then origin+handle, then origin+name
  cid := p_conversation_id;
  if cid is null and p_conv_external_id is not null then select id into cid from public.conversations where origin = p_origin and external_id = p_conv_external_id; end if;
  if cid is null and nullif(btrim(p_order_number),'') is not null then select id into cid from public.conversations where origin = p_origin and order_number = btrim(p_order_number) order by last_message_at desc nulls last limit 1; end if;
  if cid is null and nullif(btrim(p_customer_handle),'') is not null then select id into cid from public.conversations where origin = p_origin and lower(customer_handle) = lower(btrim(p_customer_handle)) order by last_message_at desc nulls last limit 1; end if;
  if cid is null and nullif(btrim(p_customer_name),'') is not null then select id into cid from public.conversations where origin = p_origin and lower(customer_name) = lower(btrim(p_customer_name)) order by last_message_at desc nulls last limit 1; end if;
  if cid is null then
    insert into public.conversations (origin, shop, customer_name, customer_handle, subject, order_number, status, summary, external_id)
    values (p_origin, coalesce(p_shop, public.cx_channel_label(p_origin)), p_customer_name, p_customer_handle, p_subject, p_order_number, 'awaiting_customer',
            'Created when Eggsy logged a sent reply', coalesce(p_conv_external_id, 'sent-log:' || gen_random_uuid()))
    returning id into cid;
  end if;
  ext := coalesce(p_external_id, 'sent:' || cid || ':' || to_char(p_sent_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  -- 2) outbound message (idempotent)
  insert into public.messages (conversation_id, direction, author, body, sent_at, external_id)
  values (cid, 'outbound', p_author, p_body, p_sent_at, ext)
  on conflict (conversation_id, external_id) do update set body = excluded.body
  returning id into mid;
  -- 3) log entry (idempotent on external_id)
  insert into public.sent_log (sent_at, conversation_id, message_id, origin, shop, customer_name, customer_handle, order_number, body, route, approved_by, external_id)
  values (p_sent_at, cid, mid, p_origin, p_shop, p_customer_name, p_customer_handle, p_order_number, p_body, p_route, p_approved_by, ext)
  on conflict (external_id) where external_id is not null do nothing
  returning id into lid;
  if lid is null then select id into lid from public.sent_log where external_id = ext; end if;
  -- 4) conversation now waits on the customer
  update public.conversations set status = 'awaiting_customer', updated_at = now() where id = cid;
  return lid;
end $$;

revoke execute on function public.cx_log_sent_reply(public.cx_origin,text,text,timestamptz,uuid,text,text,text,text,text,text,text,text,text) from public, anon, authenticated;
revoke execute on function public.reply_queue_log_sent() from public, anon, authenticated;
revoke execute on function public.sent_log_before_insert() from public, anon, authenticated;