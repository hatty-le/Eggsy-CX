-- Applied via MCP on 18 Nov 2026 (cx_customer_merge).
-- One customer, one ticket.
-- Same person = same customer email (any channel that stores one), or the same order
-- number inside one shop family, or the same buyer handle inside one channel and shop.
-- Generic handles, platform mailboxes, and Amazon relays that are not buyer-specific
-- are not identities. A shared name is not an identity.
-- A new insert attaches to the open ticket. cx_merge_conversations moves the history
-- and keeps the other row, marked merged, so it leaves the inbox counts.

-- ---------------------------------------------------------------------------
-- Identity helpers
-- ---------------------------------------------------------------------------

create or replace function public.cx_normalise_email(p_raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim((
    select case
      when t ~ '<[^<>]+@[^<>]+>' then (regexp_match(t, '<([^<>]+@[^<>]+)>'))[1]
      else regexp_replace(t, '^mailto:', '')
    end
    from (select lower(btrim(coalesce(p_raw, ''))) as t) s
  )), '')
$$;

create or replace function public.cx_email_is_customer(p_raw text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  with e as (
    select public.cx_normalise_email(p_raw) as addr
  ),
  p as (
    select addr,
           split_part(addr, '@', 1) as local,
           split_part(addr, '@', 2) as domain
    from e
    where addr ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  )
  select coalesce((
    select
      local !~ '^(no[-_.]?reply|do[-_.]?not[-_.]?reply|donotreply|mailer|mailer-daemon|notification|notifications|postmaster|bounce|bounces|newsletter|automated|alerts|notify|system)$'
      and local !~ '(^|[._-])(no[-_.]?reply|donotreply|mailer|notification)([._-]|$)'
      and domain !~ '(^|\.)(shopify|shopifyemail|facebookmail|facebook|wix|netlify|klaviyo|walmart)\.com$'
      and domain not in ('google.com', 'fb.com', 'meta.com', 'tiktok.com', 'crm.wix.com', 'email.shopify.com')
      and domain !~ '(^|\.)google\.com$'
      and (
        domain !~ '(^|\.)tiktok\.com$'
        or (domain ~ '^scs[0-9]*\.tiktok\.com$' and length(local) >= 20)
      )
      and not (
        domain ~ '(^|\.)amazon\.[a-z.]+$'
        and addr !~ '^[a-z0-9]+\+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@marketplace\.amazon\.[a-z.]+$'
      )
    from p
  ), false)
$$;

create or replace function public.cx_normalise_handle(p_raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(regexp_replace(lower(btrim(coalesce(p_raw, ''))), '^@+', ''), '')
$$;

-- Platform handles that are not one person. Emails are matched separately.
create or replace function public.cx_handle_is_customer(p_raw text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  with h as (
    select public.cx_normalise_handle(p_raw) as handle,
           lower(btrim(coalesce(p_raw, ''))) as raw
  )
  select coalesce((
    select length(handle) >= 3
       and handle !~ '@'
       and raw !~ '^igcomment:'
       and handle !~ '^igcomment:'
       and handle not in (
         'buyer', 'unknown', 'customer', 'user', 'guest', 'anonymous', 'na', 'n/a', 'none',
         'null', 'undefined', 'instagram user', 'facebook user', 'unknown instagram user',
         'unknown facebook user', 'unknown user'
       )
       and handle !~ '…'
       and handle !~ '\.{3,}$'
       and raw !~ 'seller assistant|tiktok shop'
    from h
    where handle is not null
  ), false)
$$;

create or replace function public.cx_normalise_order(p_raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(upper(regexp_replace(regexp_replace(btrim(coalesce(p_raw, '')), '^#+', ''), '[[:space:]]+', '', 'g')), '')
$$;

-- Shopify order numbers restart on each store. Amazon, TikTok and Walmart ids do not.
create or replace function public.cx_order_family(p_origin text, p_shop text, p_order text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when ord is null or length(ord) < 4 then null
    when ord ~ '^\d{3}-\d{7}-\d{7}$' then 'amazon'
    when ord ~ '^57\d{14,}$' then 'tiktok'
    when ord ~ '^2000\d{8,}$' then 'walmart'
    when ord ~ '^\d{4,7}$' then
      case
        when coalesce(p_shop, '') ~* 'murder|mystery|mmc' or p_origin = 'wix_mmc_form' then 'mmc'
        when coalesce(p_shop, '') ~* '\(US\)|USA' then 'le_us'
        when coalesce(p_shop, '') ~* '\(IE\)|ireland' then 'le_ie'
        when coalesce(p_shop, '') ~* '\(GB\)|\(UK\)|lucky egg' or p_origin in ('email_hey', 'shopify_form') then 'le_gb'
        else 'shop:' || lower(btrim(coalesce(nullif(p_shop, ''), p_origin, 'unknown')))
      end
    else null
  end
  from (select public.cx_normalise_order(p_order) as ord) s
$$;

create or replace function public.cx_platform_ticket(p_name text, p_handle text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_name, '') ~* '(seller assistant|amazon ads|^facebook$|meta for business|google merchant|google voice|^netlify$|^shopify$|lucky egg \(shopify\)|partner performance|^no-?reply$|do ?not ?reply|mailer-daemon|^postmaster$)'
      or (
        coalesce(p_handle, '') ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+'
        and not public.cx_email_is_customer(p_handle)
      )
$$;

create or replace function public.cx_merge_allowed()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select public.is_lucky_egg_staff()
      or coalesce(auth.role(), '') in ('service_role', 'supabase_admin')
      or session_user in ('postgres', 'supabase_admin', 'service_role')
$$;

revoke all on function public.cx_normalise_email(text) from public, anon, authenticated;
revoke all on function public.cx_email_is_customer(text) from public, anon, authenticated;
revoke all on function public.cx_normalise_handle(text) from public, anon, authenticated;
revoke all on function public.cx_handle_is_customer(text) from public, anon, authenticated;
revoke all on function public.cx_normalise_order(text) from public, anon, authenticated;
revoke all on function public.cx_order_family(text, text, text) from public, anon, authenticated;
revoke all on function public.cx_platform_ticket(text, text) from public, anon, authenticated;
revoke all on function public.cx_merge_allowed() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Columns, merge log, inbox filter
-- ---------------------------------------------------------------------------

alter table public.conversations
  add column if not exists merged_into uuid references public.conversations (id),
  add column if not exists merged_at timestamptz,
  add column if not exists merged_from uuid[] not null default '{}';

alter table public.conversations
  drop constraint if exists conversations_not_merged_into_self;
alter table public.conversations
  add constraint conversations_not_merged_into_self check (merged_into is null or merged_into <> id);

create index if not exists conversations_merged_into_idx
  on public.conversations (merged_into) where merged_into is not null;

alter table public.messages add column if not exists origin public.cx_origin;
alter table public.messages add column if not exists shop text;
alter table public.messages add column if not exists source_conversation_id uuid;
alter table public.suggested_drafts add column if not exists source_conversation_id uuid;
alter table public.reply_queue add column if not exists source_conversation_id uuid;
alter table public.reply_queue add column if not exists send_origin public.cx_origin;
alter table public.cx_actions add column if not exists source_conversation_id uuid;
alter table public.sent_log add column if not exists source_conversation_id uuid;
alter table public.cx_followups add column if not exists source_conversation_id uuid;
alter table public.cx_order_links add column if not exists source_conversation_id uuid;
alter table public.cx_email_filing_log add column if not exists source_conversation_id uuid;
alter table public.cx_reviews add column if not exists source_conversation_id uuid;

update public.messages m
   set origin = c.origin,
       shop = c.shop
  from public.conversations c
 where c.id = m.conversation_id
   and m.origin is null;

create index if not exists messages_source_conversation_idx
  on public.messages (source_conversation_id) where source_conversation_id is not null;

grant insert (send_origin) on public.reply_queue to authenticated;
grant select (send_origin) on public.reply_queue to authenticated;

create table if not exists public.cx_conversation_merges (
  id uuid primary key default gen_random_uuid(),
  keep_id uuid not null references public.conversations (id) on delete cascade,
  merged_id uuid not null references public.conversations (id) on delete cascade,
  merged_at timestamptz not null default now(),
  undone_at timestamptz,
  snapshot jsonb not null default '{}'::jsonb
);

create unique index if not exists cx_conversation_merges_active
  on public.cx_conversation_merges (merged_id) where undone_at is null;

alter table public.cx_conversation_merges enable row level security;
alter table public.cx_conversation_merges force row level security;
revoke all on public.cx_conversation_merges from anon, authenticated;
grant select on public.cx_conversation_merges to authenticated;

drop policy if exists "staff read merges" on public.cx_conversation_merges;
create policy "staff read merges" on public.cx_conversation_merges
  for select to authenticated using ((select public.is_lucky_egg_staff()));

comment on table public.cx_conversation_merges is
  'History of ticket merges. The merged conversation row stays; undone_at is set by Unmerge.';

-- Merged shells stay in the table but drop out of inbox, waiting, resolved and junk counts.
create or replace view public.cx_conversation_state with (security_invoker = true) as
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
    where reply_queue.status = any (array['queued'::public.cx_send_status, 'sending'::public.cx_send_status, 'sent'::public.cx_send_status])
    group by reply_queue.conversation_id
 ),
 s as (
   select c.id as conversation_id,
          c.status,
          c.status_changed_at,
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
          s.last_customer_at,
          s.last_reply_at,
          s.status = 'resolved'::public.cx_status
            and not (
              s.status_changed_at is not null
              and s.last_customer_at > s.status_changed_at
              and (s.last_reply_at is null or s.last_customer_at > s.last_reply_at)
            ) as closed
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

-- ---------------------------------------------------------------------------
-- Match and follow a merged ticket
-- ---------------------------------------------------------------------------

create or replace function public.cx_conversation_root(p_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cur uuid := p_id;
  nxt uuid;
  i int := 0;
begin
  if p_id is null then
    return null;
  end if;
  loop
    select merged_into into nxt from public.conversations where id = cur;
    exit when nxt is null or i >= 8;
    cur := nxt;
    i := i + 1;
  end loop;
  return cur;
end
$$;

create or replace function public.cx_match_customer_ticket(
  p_origin public.cx_origin,
  p_shop text,
  p_customer_handle text,
  p_order_number text,
  p_exclude uuid default null,
  p_kind text default 'message',
  p_customer_name text default null
) returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_email text;
  v_handle text;
  v_order text;
  v_family text;
  v_shop text := lower(btrim(coalesce(p_shop, '')));
  v_id uuid;
begin
  if p_kind is not null and p_kind <> 'message' then
    return null;
  end if;
  if public.cx_platform_ticket(p_customer_name, p_customer_handle) then
    return null;
  end if;

  v_email := case when public.cx_email_is_customer(p_customer_handle) then public.cx_normalise_email(p_customer_handle) else null end;
  v_handle := case when public.cx_handle_is_customer(p_customer_handle) then public.cx_normalise_handle(p_customer_handle) else null end;
  v_order := public.cx_normalise_order(p_order_number);
  v_family := public.cx_order_family(p_origin::text, p_shop, v_order);
  if v_email is null and v_handle is null and v_family is null then
    return null;
  end if;

  with pool as (
    select c.id,
           case when public.cx_email_is_customer(c.customer_handle) then public.cx_normalise_email(c.customer_handle) else null end as cust_email,
           case when public.cx_handle_is_customer(c.customer_handle) then public.cx_normalise_handle(c.customer_handle) else null end as cust_handle,
           public.cx_normalise_order(c.order_number) as onum,
           public.cx_order_family(c.origin::text, c.shop, public.cx_normalise_order(c.order_number)) as family,
           c.origin,
           lower(btrim(coalesce(c.shop, ''))) as shop_key,
           coalesce((select max(m.sent_at) from public.messages m where m.conversation_id = c.id), c.last_message_at) as activity,
           c.created_at
      from public.conversations c
     where c.merged_into is null
       and c.id is distinct from p_exclude
       and c.status <> 'ignored'::public.cx_status
       and coalesce(c.kind, 'message') = 'message'
       and not public.cx_platform_ticket(c.customer_name, c.customer_handle)
  ),
  email_c as (
    select * from pool where v_email is not null and cust_email = v_email
  ),
  order_c as (
    select * from pool where v_family is not null and family = v_family and onum = v_order
  ),
  handle_c as (
    select * from pool
     where v_handle is not null
       and cust_handle = v_handle
       and origin = p_origin
       and shop_key = v_shop
  ),
  order_ok as (
    select * from order_c
     where (select count(distinct cust_email) from order_c where cust_email is not null) <= 1
       and (
         v_email is null
         or not exists (select 1 from order_c where cust_email is not null and cust_email <> v_email)
       )
  ),
  handle_ok as (
    select * from handle_c
     where (select count(distinct cust_email) from handle_c where cust_email is not null) <= 1
       and (
         v_email is null
         or not exists (select 1 from handle_c where cust_email is not null and cust_email <> v_email)
       )
  ),
  cands as (
    select id, activity, created_at, cust_email from email_c
    union
    select id, activity, created_at, cust_email from order_ok
    union
    select id, activity, created_at, cust_email from handle_ok
  )
  select id into v_id
    from cands
   where (select count(distinct cust_email) from cands where cust_email is not null) <= 1
   order by activity desc nulls last, created_at desc
   limit 1;

  return v_id;
end
$fn$;

create or replace function public.cx_find_customer_ticket(
  p_origin public.cx_origin,
  p_shop text,
  p_customer_handle text,
  p_order_number text,
  p_exclude uuid default null,
  p_kind text default 'message',
  p_customer_name text default null
) returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.cx_merge_allowed() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return public.cx_match_customer_ticket(p_origin, p_shop, p_customer_handle, p_order_number, p_exclude, p_kind, p_customer_name);
end
$$;

create or replace function public.cx_reply_origin(p_conversation uuid, p_requested public.cx_origin default null)
returns public.cx_origin
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  conv public.cx_origin;
  chosen public.cx_origin;
begin
  p_conversation := public.cx_conversation_root(p_conversation);
  select origin into conv from public.conversations where id = p_conversation;
  if p_requested is not null and (
    p_requested = conv
    or exists (
      select 1 from public.messages m
       where m.conversation_id = p_conversation and m.origin = p_requested
    )
    or exists (
      select 1 from public.conversations s
       where s.merged_into = p_conversation and s.origin = p_requested
    )
  ) then
    return p_requested;
  end if;
  select m.origin into chosen
    from public.messages m
   where m.conversation_id = p_conversation
     and m.direction = 'inbound'
     and m.origin is not null
     and coalesce(m.body, '') !~ '^\[Summary by Eggsy'
   order by m.sent_at desc
   limit 1;
  return coalesce(chosen, conv);
end
$$;

revoke all on function public.cx_conversation_root(uuid) from public, anon, authenticated;
revoke all on function public.cx_match_customer_ticket(public.cx_origin, text, text, text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.cx_find_customer_ticket(public.cx_origin, text, text, text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.cx_reply_origin(uuid, public.cx_origin) from public, anon, authenticated;
grant execute on function public.cx_find_customer_ticket(public.cx_origin, text, text, text, uuid, text, text) to authenticated, service_role;
grant execute on function public.cx_reply_origin(uuid, public.cx_origin) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Redirect anything inserted against a merged shell onto the kept ticket
-- ---------------------------------------------------------------------------

create or replace function public.cx_redirect_merged_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  root uuid;
begin
  if coalesce(current_setting('eggsy.skip_redirect', true), '') = 'on' then
    return new;
  end if;
  if new.conversation_id is null then
    return new;
  end if;
  if tg_op = 'INSERT' and new.source_conversation_id is null then
    new.source_conversation_id := new.conversation_id;
  end if;
  root := public.cx_conversation_root(new.conversation_id);
  if root is not null and root is distinct from new.conversation_id then
    new.conversation_id := root;
  end if;
  return new;
end
$$;

create or replace function public.cx_redirect_merged_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  root uuid;
  src_origin public.cx_origin;
  src_shop text;
begin
  if new.conversation_id is null then
    return new;
  end if;
  select origin, shop into src_origin, src_shop
    from public.conversations where id = new.conversation_id;
  if new.origin is null then
    new.origin := src_origin;
  end if;
  if new.shop is null then
    new.shop := src_shop;
  end if;
  if coalesce(current_setting('eggsy.skip_redirect', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'INSERT' and new.source_conversation_id is null then
    new.source_conversation_id := new.conversation_id;
  end if;
  root := public.cx_conversation_root(new.conversation_id);
  if root is not null and root is distinct from new.conversation_id then
    new.conversation_id := root;
  end if;
  return new;
end
$$;

revoke all on function public.cx_redirect_merged_row() from public, anon, authenticated;
revoke all on function public.cx_redirect_merged_message() from public, anon, authenticated;

drop trigger if exists aaa_redirect_merged_message on public.messages;
create trigger aaa_redirect_merged_message
  before insert or update of conversation_id on public.messages
  for each row execute function public.cx_redirect_merged_message();

drop trigger if exists aaa_redirect_merged on public.suggested_drafts;
create trigger aaa_redirect_merged
  before insert or update of conversation_id on public.suggested_drafts
  for each row execute function public.cx_redirect_merged_row();

-- One current draft per ticket. A second insert keeps the newer one.
create or replace function public.cx_keep_newest_draft()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing record;
begin
  if coalesce(new.superseded, false) or new.conversation_id is null then
    return new;
  end if;
  if coalesce(current_setting('eggsy.skip_redirect', true), '') = 'on' then
    return new;
  end if;
  select id, drafted_at into existing
    from public.suggested_drafts
   where conversation_id = new.conversation_id
     and superseded = false
   order by drafted_at desc nulls last, created_at desc
   limit 1;
  if existing.id is null then
    return new;
  end if;
  if coalesce(new.drafted_at, pg_catalog.now()) >= coalesce(existing.drafted_at, '-infinity'::timestamptz) then
    update public.suggested_drafts
       set superseded = true, superseded_at = pg_catalog.now()
     where id = existing.id;
  else
    new.superseded := true;
    new.superseded_at := pg_catalog.now();
  end if;
  return new;
end
$$;

revoke all on function public.cx_keep_newest_draft() from public, anon, authenticated;
drop trigger if exists aab_keep_newest_draft on public.suggested_drafts;
create trigger aab_keep_newest_draft
  before insert on public.suggested_drafts
  for each row execute function public.cx_keep_newest_draft();

drop trigger if exists aaa_redirect_merged on public.reply_queue;
create trigger aaa_redirect_merged
  before insert or update of conversation_id on public.reply_queue
  for each row execute function public.cx_redirect_merged_row();

drop trigger if exists aaa_redirect_merged on public.cx_actions;
create trigger aaa_redirect_merged
  before insert or update of conversation_id on public.cx_actions
  for each row execute function public.cx_redirect_merged_row();

drop trigger if exists aaa_redirect_merged on public.sent_log;
create trigger aaa_redirect_merged
  before insert or update of conversation_id on public.sent_log
  for each row execute function public.cx_redirect_merged_row();

drop trigger if exists aaa_redirect_merged on public.cx_followups;
create trigger aaa_redirect_merged
  before insert or update of conversation_id on public.cx_followups
  for each row execute function public.cx_redirect_merged_row();

drop trigger if exists aaa_redirect_merged on public.cx_order_links;
create trigger aaa_redirect_merged
  before insert or update of conversation_id on public.cx_order_links
  for each row execute function public.cx_redirect_merged_row();

drop trigger if exists aaa_redirect_merged on public.cx_email_filing_log;
create trigger aaa_redirect_merged
  before insert or update of conversation_id on public.cx_email_filing_log
  for each row execute function public.cx_redirect_merged_row();

drop trigger if exists aaa_redirect_merged on public.cx_reviews;
create trigger aaa_redirect_merged
  before insert or update of conversation_id on public.cx_reviews
  for each row execute function public.cx_redirect_merged_row();

create or replace function public.cx_conversations_match_customer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  match uuid;
  keep public.conversations%rowtype;
begin
  if coalesce(current_setting('eggsy.skip_redirect', true), '') = 'on' then
    return new;
  end if;

  if tg_when = 'AFTER' then
    if new.merged_into is null then
      return new;
    end if;
    if exists (
      select 1 from public.cx_conversation_merges
       where merged_id = new.id and undone_at is null
    ) then
      return new;
    end if;
    select * into keep from public.conversations where id = new.merged_into;
    if not found then
      return new;
    end if;
    update public.conversations
       set merged_from = (
         select coalesce(array_agg(distinct x), '{}'::uuid[])
           from unnest(coalesce(merged_from, '{}'::uuid[]) || new.id) as x
       )
     where id = keep.id;
    insert into public.cx_conversation_merges (keep_id, merged_id, snapshot)
    values (
      keep.id,
      new.id,
      jsonb_build_object(
        'via', 'ingest',
        'keep_status', keep.status,
        'keep_origin', keep.origin,
        'keep_shop', keep.shop,
        'keep_external_id', keep.external_id,
        'keep_subject', keep.subject,
        'keep_customer_name', keep.customer_name,
        'keep_customer_handle', keep.customer_handle,
        'keep_order_number', keep.order_number
      )
    );
    return new;
  end if;

  if new.merged_into is not null or new.status = 'ignored'::public.cx_status then
    return new;
  end if;
  if coalesce(new.kind, 'message') <> 'message' then
    return new;
  end if;
  if public.cx_platform_ticket(new.customer_name, new.customer_handle) then
    return new;
  end if;

  if tg_when = 'BEFORE' then
    match := public.cx_match_customer_ticket(
      new.origin, new.shop, new.customer_handle, new.order_number, new.id, new.kind, new.customer_name
    );
    if match is null or match = new.id then
      return new;
    end if;
    new.merged_into := match;
    new.merged_at := pg_catalog.now();
    return new;
  end if;

  return new;
end
$fn$;

revoke all on function public.cx_conversations_match_customer() from public, anon, authenticated;

drop trigger if exists conversations_match_customer on public.conversations;
create trigger conversations_match_customer
  before insert on public.conversations
  for each row execute function public.cx_conversations_match_customer();

drop trigger if exists conversations_match_customer_log on public.conversations;
create trigger conversations_match_customer_log
  after insert on public.conversations
  for each row execute function public.cx_conversations_match_customer();

-- ---------------------------------------------------------------------------
-- Merge and unmerge
-- ---------------------------------------------------------------------------

create or replace function public.cx_merge_conversations(p_keep uuid, p_merge uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  keep public.conversations%rowtype;
  other public.conversations%rowtype;
  keep_last timestamptz;
  other_last timestamptz;
  other_newer boolean;
  winner uuid;
  snap jsonb;
begin
  if not public.cx_merge_allowed() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_keep is null or p_merge is null then
    raise exception 'keep and merge are required';
  end if;
  if p_keep = p_merge then
    return p_keep;
  end if;

  p_keep := public.cx_conversation_root(p_keep);
  if p_merge = p_keep then
    return p_keep;
  end if;

  select * into other from public.conversations where id = p_merge for update;
  if not found then
    raise exception 'ticket to merge was not found';
  end if;
  if other.merged_into is not null and other.merged_into <> p_keep then
    raise exception 'that ticket is already merged into another ticket';
  end if;
  if other.merged_into = p_keep then
    return p_keep;
  end if;

  select * into keep from public.conversations where id = p_keep for update;
  if not found then
    raise exception 'ticket to keep was not found';
  end if;
  if exists (select 1 from public.cx_reviews r where r.conversation_id = p_keep)
     and exists (select 1 from public.cx_reviews r where r.conversation_id = p_merge) then
    raise exception 'both tickets have a product review, so they were left separate';
  end if;

  select coalesce(max(sent_at), keep.last_message_at) into keep_last
    from public.messages where conversation_id = p_keep;
  select coalesce(max(sent_at), other.last_message_at) into other_last
    from public.messages where conversation_id = p_merge;
  other_newer := other_last is not null and (keep_last is null or other_last > keep_last);

  snap := jsonb_build_object(
    'via', 'merge',
    'keep_status', keep.status,
    'keep_origin', keep.origin,
    'keep_shop', keep.shop,
    'keep_external_id', keep.external_id,
    'keep_subject', keep.subject,
    'keep_customer_name', keep.customer_name,
    'keep_customer_handle', keep.customer_handle,
    'keep_order_number', keep.order_number,
    'merge_status', other.status,
    'merge_origin', other.origin,
    'merge_shop', other.shop,
    'merge_external_id', other.external_id,
    'merge_subject', other.subject,
    'merge_customer_name', other.customer_name,
    'merge_customer_handle', other.customer_handle,
    'merge_order_number', other.order_number,
    'drafts', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'superseded', d.superseded, 'superseded_at', d.superseded_at))
        from public.suggested_drafts d
       where d.conversation_id in (p_keep, p_merge)
    ), '[]'::jsonb),
    'reads', coalesce((
      select jsonb_agg(jsonb_build_object('user_email', r.user_email, 'read_at', r.read_at))
        from public.cx_reads r where r.conversation_id = p_merge
    ), '[]'::jsonb),
    'keep_reads', coalesce((
      select jsonb_agg(r.user_email) from public.cx_reads r where r.conversation_id = p_keep
    ), '[]'::jsonb)
  );

  perform set_config('eggsy.skip_redirect', 'on', true);

  update public.messages m
     set external_id = m.external_id || ':m:' || left(m.id::text, 8)
   where m.conversation_id = p_merge
     and m.external_id is not null
     and exists (
       select 1 from public.messages k
        where k.conversation_id = p_keep and k.external_id = m.external_id
     );

  update public.messages
     set source_conversation_id = coalesce(source_conversation_id, conversation_id),
         conversation_id = p_keep
   where conversation_id = p_merge;

  select d.id into winner
    from public.suggested_drafts d
   where d.conversation_id in (p_keep, p_merge)
     and d.superseded = false
   order by d.drafted_at desc nulls last, d.created_at desc
   limit 1;
  if winner is not null then
    update public.suggested_drafts
       set superseded = true,
           superseded_at = pg_catalog.now()
     where conversation_id in (p_keep, p_merge)
       and superseded = false
       and id <> winner;
  end if;

  update public.suggested_drafts
     set source_conversation_id = coalesce(source_conversation_id, conversation_id),
         conversation_id = p_keep
   where conversation_id = p_merge;

  update public.reply_queue
     set source_conversation_id = coalesce(source_conversation_id, conversation_id),
         conversation_id = p_keep
   where conversation_id = p_merge;

  update public.cx_actions
     set source_conversation_id = coalesce(source_conversation_id, conversation_id),
         conversation_id = p_keep
   where conversation_id = p_merge;

  update public.sent_log
     set source_conversation_id = coalesce(source_conversation_id, conversation_id),
         conversation_id = p_keep
   where conversation_id = p_merge;

  update public.cx_followups
     set source_conversation_id = coalesce(source_conversation_id, conversation_id),
         conversation_id = p_keep
   where conversation_id = p_merge;

  update public.cx_email_filing_log
     set source_conversation_id = coalesce(source_conversation_id, conversation_id),
         conversation_id = p_keep
   where conversation_id = p_merge;

  delete from public.cx_order_links l
   where l.conversation_id = p_merge
     and exists (
       select 1 from public.cx_order_links k
        where k.order_id = l.order_id and k.conversation_id = p_keep
     );
  update public.cx_order_links
     set source_conversation_id = coalesce(source_conversation_id, conversation_id),
         conversation_id = p_keep
   where conversation_id = p_merge;

  update public.cx_reads k
     set read_at = greatest(k.read_at, m.read_at)
    from public.cx_reads m
   where k.conversation_id = p_keep
     and m.conversation_id = p_merge
     and k.user_email = m.user_email;
  delete from public.cx_reads m
   using public.cx_reads k
   where m.conversation_id = p_merge
     and k.conversation_id = p_keep
     and k.user_email = m.user_email;
  update public.cx_reads
     set conversation_id = p_keep
   where conversation_id = p_merge;

  update public.cx_reviews
     set source_conversation_id = coalesce(source_conversation_id, conversation_id),
         conversation_id = p_keep
   where conversation_id = p_merge;

  update public.conversations
     set merged_into = p_keep,
         merged_at = pg_catalog.now(),
         updated_at = pg_catalog.now()
   where id = p_merge;

  update public.conversations k
     set origin = case
           when other_newer
            and not exists (
              select 1 from public.conversations x
               where x.id <> k.id
                 and x.origin = other.origin
                 and x.external_id is not distinct from k.external_id
            )
           then other.origin
           else k.origin
         end,
         shop = case when other_newer then coalesce(other.shop, k.shop) else k.shop end,
         subject = case
           when other_newer and nullif(btrim(other.subject), '') is not null then other.subject
           else k.subject
         end,
         customer_handle = case
           when public.cx_email_is_customer(other.customer_handle)
            and not public.cx_email_is_customer(k.customer_handle)
           then other.customer_handle
           else k.customer_handle
         end,
         customer_name = coalesce(k.customer_name, other.customer_name),
         order_number = case
           when nullif(btrim(k.order_number), '') is null then other.order_number
           when other_newer and nullif(btrim(other.order_number), '') is not null then other.order_number
           else k.order_number
         end,
         flag = coalesce(k.flag, other.flag),
         flagged_at = case when k.flag is null and other.flag is not null then other.flagged_at else k.flagged_at end,
         is_mmc = k.is_mmc or other.is_mmc,
         merged_from = (
           select coalesce(array_agg(distinct x), '{}'::uuid[])
             from unnest(coalesce(k.merged_from, '{}'::uuid[]) || p_merge) as x
         ),
         last_message_at = (
           select max(m.sent_at) from public.messages m where m.conversation_id = p_keep
         ),
         updated_at = pg_catalog.now()
   where k.id = p_keep;

  update public.conversations c
     set status = 'open'::public.cx_status,
         status_changed_at = pg_catalog.now()
   where c.id = p_keep
     and c.status in ('resolved'::public.cx_status, 'awaiting_customer'::public.cx_status)
     and exists (
       select 1 from public.messages i
        where i.conversation_id = p_keep
          and i.direction = 'inbound'
          and i.sent_at > coalesce(c.status_changed_at, '-infinity'::timestamptz)
          and not exists (
            select 1 from public.messages o
             where o.conversation_id = p_keep
               and o.direction = 'outbound'
               and o.sent_at >= i.sent_at
               and not public.cx_is_internal_outbound(o.author, o.body)
          )
     );

  insert into public.cx_conversation_merges (keep_id, merged_id, snapshot)
  values (p_keep, p_merge, snap);

  begin
    perform public.cx_refresh_conversation_mmc(p_keep);
  exception when others then
    null;
  end;

  return p_keep;
end
$fn$;

create or replace function public.cx_unmerge_conversation(p_merged uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  log public.cx_conversation_merges%rowtype;
  keep uuid;
  draft jsonb;
  rd jsonb;
begin
  if not public.cx_merge_allowed() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into log
    from public.cx_conversation_merges
   where merged_id = p_merged
     and undone_at is null
   order by merged_at desc
   limit 1;
  if not found then
    raise exception 'this ticket is not merged';
  end if;
  if exists (
    select 1 from public.cx_conversation_merges later
     where later.keep_id = log.keep_id
       and later.undone_at is null
       and later.merged_at > log.merged_at
  ) then
    raise exception 'unmerge the later ticket first';
  end if;

  keep := log.keep_id;
  perform set_config('eggsy.skip_redirect', 'on', true);

  update public.messages set conversation_id = p_merged where source_conversation_id = p_merged;
  update public.suggested_drafts set conversation_id = p_merged where source_conversation_id = p_merged;
  update public.reply_queue set conversation_id = p_merged where source_conversation_id = p_merged;
  update public.cx_actions set conversation_id = p_merged where source_conversation_id = p_merged;
  update public.sent_log set conversation_id = p_merged where source_conversation_id = p_merged;
  update public.cx_followups set conversation_id = p_merged where source_conversation_id = p_merged;
  update public.cx_email_filing_log set conversation_id = p_merged where source_conversation_id = p_merged;
  update public.cx_order_links set conversation_id = p_merged where source_conversation_id = p_merged;
  update public.cx_reviews set conversation_id = p_merged where source_conversation_id = p_merged;

  for draft in
    select value from jsonb_array_elements(coalesce(log.snapshot->'drafts', '[]'::jsonb))
  loop
    update public.suggested_drafts
       set superseded = coalesce((draft->>'superseded')::boolean, superseded),
           superseded_at = case
             when draft ? 'superseded_at' and draft->>'superseded_at' is not null then (draft->>'superseded_at')::timestamptz
             when coalesce((draft->>'superseded')::boolean, false) = false then null
             else superseded_at
           end
     where id = (draft->>'id')::uuid;
  end loop;

  if log.snapshot ? 'reads' then
    for rd in select value from jsonb_array_elements(log.snapshot->'reads')
    loop
      if not (coalesce(log.snapshot->'keep_reads', '[]'::jsonb) ? (rd->>'user_email')) then
        update public.cx_reads
           set conversation_id = p_merged
         where conversation_id = keep
           and user_email = rd->>'user_email';
      else
        insert into public.cx_reads (conversation_id, user_email, read_at)
        values (p_merged, rd->>'user_email', (rd->>'read_at')::timestamptz)
        on conflict (conversation_id, user_email) do update set read_at = excluded.read_at;
      end if;
    end loop;
  end if;

  update public.conversations
     set merged_into = null,
         merged_at = null,
         status = coalesce((log.snapshot->>'merge_status')::public.cx_status, status),
         origin = coalesce((log.snapshot->>'merge_origin')::public.cx_origin, origin),
         shop = coalesce(log.snapshot->>'merge_shop', shop),
         external_id = coalesce(log.snapshot->>'merge_external_id', external_id),
         subject = coalesce(log.snapshot->>'merge_subject', subject),
         customer_name = coalesce(log.snapshot->>'merge_customer_name', customer_name),
         customer_handle = coalesce(log.snapshot->>'merge_customer_handle', customer_handle),
         order_number = coalesce(log.snapshot->>'merge_order_number', order_number),
         last_message_at = (select max(sent_at) from public.messages where conversation_id = p_merged),
         updated_at = pg_catalog.now()
   where id = p_merged;

  update public.conversations
     set merged_from = array_remove(coalesce(merged_from, '{}'::uuid[]), p_merged),
         status = coalesce((log.snapshot->>'keep_status')::public.cx_status, status),
         origin = coalesce((log.snapshot->>'keep_origin')::public.cx_origin, origin),
         shop = case when log.snapshot ? 'keep_shop' then log.snapshot->>'keep_shop' else shop end,
         external_id = case when log.snapshot ? 'keep_external_id' then log.snapshot->>'keep_external_id' else external_id end,
         subject = case when log.snapshot ? 'keep_subject' then log.snapshot->>'keep_subject' else subject end,
         customer_name = case when log.snapshot ? 'keep_customer_name' then log.snapshot->>'keep_customer_name' else customer_name end,
         customer_handle = case when log.snapshot ? 'keep_customer_handle' then log.snapshot->>'keep_customer_handle' else customer_handle end,
         order_number = case when log.snapshot ? 'keep_order_number' then log.snapshot->>'keep_order_number' else order_number end,
         last_message_at = (select max(sent_at) from public.messages where conversation_id = keep),
         updated_at = pg_catalog.now()
   where id = keep;

  update public.cx_conversation_merges
     set undone_at = pg_catalog.now()
   where id = log.id;

  return p_merged;
end
$fn$;

revoke all on function public.cx_merge_conversations(uuid, uuid) from public, anon;
revoke all on function public.cx_unmerge_conversation(uuid) from public, anon;
grant execute on function public.cx_merge_conversations(uuid, uuid) to authenticated, service_role;
grant execute on function public.cx_unmerge_conversation(uuid) to authenticated, service_role;

comment on function public.cx_merge_conversations(uuid, uuid) is
  'Moves messages, drafts, the queue, actions, the sent log and linked orders onto p_keep. The other ticket stays, with merged_into set, and drops out of the inbox. The kept ticket uses the more recent ticket''s channel. One draft stays current: the newest draft that was not already superseded.';

-- Reply routing follows the latest customer message, or a channel the agent picked
-- when that channel is already on the ticket. Send guards are unchanged.
create or replace function public.reply_queue_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  c record;
  is_app boolean := coalesce((select auth.jwt()) ->> 'role', '') = 'authenticated';
  requested public.cx_origin;
  route public.cx_origin;
  src record;
begin
  if new.conversation_id is not null then
    new.conversation_id := public.cx_conversation_root(new.conversation_id);
  end if;
  select origin, shop, customer_handle, external_id into c
    from public.conversations where id = new.conversation_id;
  if not found then
    raise exception 'conversation not found';
  end if;

  requested := new.send_origin;
  if is_app then
    new.status := 'queued';
    new.queued_by := lower((select auth.jwt()) ->> 'email');
    new.queued_at := pg_catalog.now();
    new.sending_at := null;
    new.sent_at := null;
    new.sent_external_id := null;
    new.message_id := null;
    new.attempts := 0;
    new.send_error := null;
    new.cancelled_at := null;
    new.cancelled_by := null;
    new.origin := null;
    new.shop := null;
    new.to_address := null;
    new.gmail_thread_id := null;
    new.reply_to_message_id := null;
    new.send_origin := requested;
  end if;

  route := public.cx_reply_origin(new.conversation_id, coalesce(requested, new.origin));
  new.origin := route;

  select m.shop, m.external_thread_id, m.external_id
    into src
    from public.messages m
   where m.conversation_id = new.conversation_id
     and m.direction = 'inbound'
     and m.origin = route
     and coalesce(m.body, '') !~ '^\[Summary by Eggsy'
   order by m.sent_at desc
   limit 1;

  new.shop := coalesce(src.shop, new.shop, c.shop);

  if route in ('email_hey', 'shopify_form', 'wix_mmc_form') then
    if new.to_address is null and c.customer_handle like '%_@_%.%' then
      new.to_address := lower(btrim(c.customer_handle));
    end if;
    if new.gmail_thread_id is null and src.external_thread_id is not null then
      new.gmail_thread_id := src.external_thread_id;
    end if;
    if new.gmail_thread_id is null
       and c.external_id like 'gmail:%'
       and c.origin = route
       and not exists (
         select 1 from public.messages m
          where m.conversation_id = new.conversation_id
            and m.origin is not null
            and m.origin <> c.origin
       )
    then
      new.gmail_thread_id := substr(c.external_id, 7);
    end if;
    if new.reply_to_message_id is null and src.external_id like 'gmail:%' then
      new.reply_to_message_id := substr(src.external_id, 7);
    end if;
    if new.reply_to_message_id is null then
      select substr(m.external_id, 7) into new.reply_to_message_id
        from public.messages m
       where m.conversation_id = new.conversation_id
         and m.direction = 'inbound'
         and m.external_id like 'gmail:%'
         and (m.origin = route or m.origin is null)
       order by m.sent_at desc
       limit 1;
    end if;
  end if;
  new.updated_at := pg_catalog.now();
  return new;
end
$$;

revoke all on function public.reply_queue_before_insert() from public, anon, authenticated;

-- Sent-reply logging no longer attaches by customer name.
create or replace function public.cx_log_sent_reply(
  p_origin public.cx_origin, p_body text, p_route text,
  p_sent_at timestamptz default now(), p_conversation_id uuid default null, p_conv_external_id text default null,
  p_order_number text default null, p_customer_name text default null, p_customer_handle text default null,
  p_shop text default null, p_subject text default null, p_external_id text default null,
  p_approved_by text default 'hatty@luckyegg.co', p_author text default 'The Lucky Egg Team (sent by Eggsy)'
) returns uuid
language plpgsql
set search_path = ''
as $fn$
declare
  cid uuid; mid uuid; lid uuid; ext text; qid uuid;
begin
  if p_route not in ('approved in chat', 'email card', 'auto-approved ready') then
    raise exception 'route must be approved in chat, email card or auto-approved ready';
  end if;
  if coalesce(btrim(p_body), '') = '' then
    raise exception 'body is empty';
  end if;

  cid := p_conversation_id;
  if cid is not null then
    cid := public.cx_conversation_root(cid);
  end if;
  if cid is null and p_conv_external_id is not null then
    select public.cx_conversation_root(id) into cid
      from public.conversations
     where origin = p_origin and external_id = p_conv_external_id;
  end if;
  if cid is null then
    cid := public.cx_find_customer_ticket(p_origin, p_shop, p_customer_handle, p_order_number, null, 'message', p_customer_name);
  end if;
  if cid is null then
    insert into public.conversations (origin, shop, customer_name, customer_handle, subject, order_number, status, summary, external_id)
    values (
      p_origin,
      coalesce(p_shop, public.cx_channel_label(p_origin)),
      p_customer_name,
      p_customer_handle,
      p_subject,
      p_order_number,
      'awaiting_customer',
      'Created when Eggsy logged a sent reply',
      coalesce(p_conv_external_id, 'sent-log:' || gen_random_uuid())
    )
    returning id into cid;
    cid := public.cx_conversation_root(cid);
  end if;

  ext := coalesce(p_external_id, 'sent:' || cid || ':' || to_char(p_sent_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || ':' || left(md5(p_body), 8));

  if ext ~ '^reply_queue:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or ext ~ '^reply:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    qid := substring(ext from '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$')::uuid;
  end if;

  select m.id into mid
    from public.messages m
   where m.conversation_id = cid
     and m.direction = 'outbound'
     and (
       m.external_id = ext
       or (qid is not null and m.external_id in ('reply:' || qid, 'reply_queue:' || qid))
       or (m.body is not distinct from p_body and abs(extract(epoch from (m.sent_at - p_sent_at))) < 900)
     )
   order by (m.external_id = ext) desc,
            (qid is not null and m.external_id in ('reply:' || qid, 'reply_queue:' || qid)) desc,
            m.sent_at
   limit 1;

  if mid is null then
    insert into public.messages (conversation_id, direction, author, body, sent_at, external_id, origin, shop)
    values (cid, 'outbound', p_author, p_body, p_sent_at, ext, p_origin, p_shop)
    on conflict (conversation_id, external_id) do update set body = excluded.body
    returning id into mid;
  end if;

  select s.id into lid
    from public.sent_log s
   where (s.external_id is not null and s.external_id = ext)
      or (qid is not null and s.reply_queue_id = qid)
      or (qid is not null and s.external_id in ('reply:' || qid, 'reply_queue:' || qid))
      or (mid is not null and s.message_id = mid)
      or (s.conversation_id = cid and s.body is not distinct from p_body
          and abs(extract(epoch from (s.sent_at - p_sent_at))) < 900)
   order by (s.external_id is not distinct from ext) desc,
            (s.route = p_route) desc,
            (s.route is distinct from 'queued in Eggsy CX') desc,
            s.sent_at
   limit 1;

  if lid is null then
    insert into public.sent_log (sent_at, conversation_id, message_id, reply_queue_id, origin, shop, customer_name, customer_handle, order_number, body, route, approved_by, external_id)
    values (p_sent_at, cid, mid, qid, p_origin, p_shop, p_customer_name, p_customer_handle, p_order_number, p_body, p_route, p_approved_by, ext)
    on conflict (external_id) where external_id is not null do nothing
    returning id into lid;
    if lid is null then
      select id into lid from public.sent_log where external_id = ext;
    end if;
  else
    update public.sent_log s
       set message_id = coalesce(s.message_id, mid),
           reply_queue_id = coalesce(s.reply_queue_id, qid),
           route = case when s.route = 'queued in Eggsy CX' then p_route else s.route end,
           approved_by = coalesce(nullif(btrim(s.approved_by), ''), p_approved_by)
     where s.id = lid;
  end if;

  perform public.cx_supersede_drafts_on_send(cid);
  update public.conversations
     set status = 'awaiting_customer', updated_at = pg_catalog.now()
   where id = cid
     and not (status = 'resolved' and last_message_at is not null and last_message_at > p_sent_at);
  return lid;
end
$fn$;

revoke all on function public.cx_log_sent_reply(public.cx_origin, text, text, timestamptz, uuid, text, text, text, text, text, text, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Duplicate report and backfill
-- ---------------------------------------------------------------------------

create or replace function public.cx_customer_duplicate_report()
returns table(action text, reason text, keep_id uuid, member_ids uuid[], detail text)
language plpgsql
volatile
security definer
set search_path = pg_temp
as $fn$
declare
  rec record;
  ra uuid;
  rb uuid;
  root uuid;
  i int;
begin
  if not public.cx_merge_allowed() then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  drop table if exists pg_temp.cx_m_node;
  drop table if exists pg_temp.cx_m_key;
  drop table if exists pg_temp.cx_m_bad;

  create temp table cx_m_node on commit drop as
  select c.id,
         c.origin,
         c.shop,
         c.customer_name,
         c.customer_handle,
         c.order_number,
         c.status,
         c.last_message_at,
         c.created_at,
         case when public.cx_email_is_customer(c.customer_handle) then public.cx_normalise_email(c.customer_handle) else null end as cust_email,
         case when public.cx_handle_is_customer(c.customer_handle) then public.cx_normalise_handle(c.customer_handle) else null end as cust_handle,
         public.cx_normalise_order(c.order_number) as onum,
         public.cx_order_family(c.origin::text, c.shop, public.cx_normalise_order(c.order_number)) as family,
         c.id as parent
    from public.conversations c
   where c.merged_into is null
     and c.status <> 'ignored'::public.cx_status
     and coalesce(c.kind, 'message') = 'message'
     and not public.cx_platform_ticket(c.customer_name, c.customer_handle);

  create temp table cx_m_key on commit drop as
  select id, 'email'::text as kind, 'email:' || cust_email as k, cust_email
    from cx_m_node
   where cust_email is not null
  union all
  select id, 'order', 'order:' || family || ':' || onum, cust_email
    from cx_m_node
   where family is not null and onum is not null
  union all
  select id, 'handle', 'handle:' || origin::text || '|' || lower(btrim(coalesce(shop, ''))) || '|' || cust_handle, cust_email
    from cx_m_node
   where cust_handle is not null;

  create temp table cx_m_bad on commit drop as
  select k
    from cx_m_key
   group by k
  having count(distinct cust_email) filter (where cust_email is not null) > 1;

  for rec in
    select distinct least(a.id, b.id) as a, greatest(a.id, b.id) as b
      from cx_m_key a
      join cx_m_key b on a.k = b.k and a.id < b.id
     where a.k not in (select cx_m_bad.k from cx_m_bad)
  loop
    ra := rec.a;
    for i in 1..12 loop
      exit when (select parent from cx_m_node where id = ra) = ra;
      ra := (select parent from cx_m_node where id = ra);
    end loop;
    rb := rec.b;
    for i in 1..12 loop
      exit when (select parent from cx_m_node where id = rb) = rb;
      rb := (select parent from cx_m_node where id = rb);
    end loop;
    if ra is not null and rb is not null and ra <> rb then
      update cx_m_node set parent = ra where id = rb;
    end if;
  end loop;

  for i in 1..12 loop
    update cx_m_node n
       set parent = p.parent
      from cx_m_node p
     where n.parent = p.id
       and p.parent is distinct from p.id;
  end loop;

  for rec in
    select parent as root, array_agg(id order by id) as members
      from cx_m_node
     group by parent
    having count(*) > 1
  loop
    select n.id into root
      from cx_m_node n
     where n.parent = rec.root
     order by (
       select max(m.sent_at) from public.messages m where m.conversation_id = n.id
     ) desc nulls last,
     n.last_message_at desc nulls last,
     n.created_at desc
     limit 1;

    action := 'merge';
    reason := (
      select string_agg(distinct k.kind, '+' order by k.kind)
        from cx_m_key k
       where k.id = any (rec.members)
         and k.k not in (select cx_m_bad.k from cx_m_bad)
    );
    keep_id := root;
    member_ids := rec.members;
    detail := (
      select string_agg(
        coalesce(n.customer_name, '?') || ' · ' || n.origin::text
          || coalesce(' · ' || n.shop, '')
          || coalesce(' · #' || n.order_number, '')
          || ' · ' || n.status::text
          || ' · ' || n.id::text,
        E'\n'
        order by n.last_message_at desc nulls last
      )
        from cx_m_node n
       where n.id = any (rec.members)
    );
    return next;
  end loop;

  for rec in
    select b.k,
           array_agg(distinct k.id order by k.id) as members,
           min(k.kind) as kind
      from cx_m_bad b
      join cx_m_key k on k.k = b.k
     group by b.k
  loop
    if (
      select count(distinct n.parent)
        from cx_m_node n
       where n.id = any (rec.members)
    ) = 1 and (
      select count(*) from cx_m_node n where n.parent = (
        select n2.parent from cx_m_node n2 where n2.id = rec.members[1]
      )
    ) >= cardinality(rec.members) then
      continue;
    end if;
    action := 'skip';
    reason := 'ambiguous ' || rec.kind || ' (different customer emails)';
    keep_id := null;
    member_ids := rec.members;
    detail := rec.k || E'\n' || coalesce((
      select string_agg(
        coalesce(n.customer_name, '?') || ' · ' || n.origin::text
          || coalesce(' · #' || n.order_number, '')
          || ' · ' || coalesce(n.cust_email, n.customer_handle, '')
          || ' · ' || n.id::text,
        E'\n'
        order by n.customer_name
      )
        from cx_m_node n
       where n.id = any (rec.members)
    ), '');
    return next;
  end loop;
end
$fn$;

create or replace function public.cx_apply_customer_merges()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
  rec record;
  mid uuid;
  groups int := 0;
  merged int := 0;
  skipped int := 0;
begin
  if not public.cx_merge_allowed() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  for rec in
    select * from public.cx_customer_duplicate_report()
  loop
    if rec.action <> 'merge' then
      skipped := skipped + 1;
      continue;
    end if;
    groups := groups + 1;
    foreach mid in array rec.member_ids loop
      if mid is distinct from rec.keep_id then
        perform public.cx_merge_conversations(rec.keep_id, mid);
        merged := merged + 1;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('groups', groups, 'merged_tickets', merged, 'skipped_groups', skipped);
end
$fn$;

revoke all on function public.cx_customer_duplicate_report() from public, anon;
revoke all on function public.cx_apply_customer_merges() from public, anon;
grant execute on function public.cx_customer_duplicate_report() to authenticated, service_role;
grant execute on function public.cx_apply_customer_merges() to service_role;

comment on function public.cx_customer_duplicate_report() is
  'Dry run of the customer-ticket merge. action=merge is safe to apply. action=skip is an order or handle shared by different email addresses.';

notify pgrst, 'reload schema';

-- Backfill. Safe to run again: tickets already merged are not offered a second time.
select public.cx_apply_customer_merges();
