-- TikTok buyer mail from hey@ arrives as "TikTok Shop Seller Assistant" with an
-- @scsN.tiktok.com relay address. The buyer is the handle in the subject
-- ("TikTok Shop customer <handle>"), matched within that ticket's shop.
-- The relay address and the assistant name are placeholders, not a person.
-- Backfill does not update reply_queue (a queued reply must stay as it was).

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
      and domain !~ '(^|\.)tiktok\.com$'
      and not (
        domain ~ '(^|\.)amazon\.[a-z.]+$'
        and addr !~ '^[a-z0-9]+\+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@marketplace\.amazon\.[a-z.]+$'
      )
    from p
  ), false)
$$;

create or replace function public.cx_is_tiktok_relay(p_raw text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(public.cx_normalise_email(p_raw), '') ~ '@scs[0-9]*\.tiktok\.com$'
$$;

create or replace function public.cx_is_tiktok_seller_assistant(p_name text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select lower(btrim(coalesce(p_name, ''))) = 'tiktok shop seller assistant'
$$;

-- "A new message from TikTok Shop customer statuschaser"
create or replace function public.cx_tiktok_subject_handle(p_subject text)
returns text
language sql
immutable
set search_path = ''
as $$
  select public.cx_normalise_handle(
    (regexp_match(coalesce(p_subject, ''), 'tiktok shop customer[[:space:]]+@?([a-z0-9][a-z0-9._-]{1,80})', 'i'))[1]
  )
$$;

revoke all on function public.cx_is_tiktok_relay(text) from public, anon, authenticated;
revoke all on function public.cx_is_tiktok_seller_assistant(text) from public, anon, authenticated;
revoke all on function public.cx_tiktok_subject_handle(text) from public, anon, authenticated;

-- A Seller Assistant / scs relay row uses the subject handle, not the relay or the assistant name.
create or replace function public.cx_conversations_match_customer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  match uuid;
  keep public.conversations%rowtype;
  buyer text;
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

  buyer := public.cx_tiktok_subject_handle(new.subject);
  if buyer is not null
     and public.cx_handle_is_customer(buyer)
     and (
       public.cx_is_tiktok_seller_assistant(new.customer_name)
       or public.cx_is_tiktok_relay(new.customer_handle)
     )
  then
    if public.cx_is_tiktok_seller_assistant(new.customer_name) then
      new.customer_name := buyer;
    end if;
    new.customer_handle := '@' || buyer;
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

-- Leave reply_queue alone when eggsy.skip_reply_queue is on. Used by the
-- Seller Assistant backfill so a reply already queued is not moved or edited.
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

  if coalesce(current_setting('eggsy.skip_reply_queue', true), '') is distinct from 'on' then
    update public.reply_queue
       set source_conversation_id = coalesce(source_conversation_id, conversation_id),
           conversation_id = p_keep
     where conversation_id = p_merge;
  end if;

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
         last_message_at = (select max(m.sent_at) from public.messages m where m.conversation_id = p_keep),
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

revoke all on function public.cx_merge_conversations(uuid, uuid) from public, anon;
grant execute on function public.cx_merge_conversations(uuid, uuid) to authenticated, service_role;

-- Dry run of Seller Assistant / scs relay tickets.
-- action merge: fold the relay ticket into the buyer's TikTok chat (or the latest
-- other relay ticket for that handle when no chat ticket exists yet).
-- action relabel: only one ticket, so store the subject handle for the next chat.
create or replace function public.cx_tiktok_assistant_plan()
returns table(action text, keep_id uuid, merge_id uuid, buyer text, shop text, detail text)
language sql
stable
security definer
set search_path = ''
as $$
  with src as (
    select c.id,
           c.origin,
           c.shop,
           lower(btrim(coalesce(c.shop, ''))) as shop_key,
           c.customer_name,
           c.customer_handle,
           c.status,
           c.last_message_at,
           public.cx_tiktok_subject_handle(c.subject) as buyer,
           public.cx_is_tiktok_seller_assistant(c.customer_name) as is_assistant,
           coalesce((select max(m.sent_at) from public.messages m where m.conversation_id = c.id), c.last_message_at) as activity
      from public.conversations c
     where c.merged_into is null
       and c.status <> 'ignored'::public.cx_status
       and coalesce(c.kind, 'message') = 'message'
       and (
         public.cx_is_tiktok_seller_assistant(c.customer_name)
         or public.cx_is_tiktok_relay(c.customer_handle)
       )
       and public.cx_handle_is_customer(public.cx_tiktok_subject_handle(c.subject))
  ),
  real_keep as (
    select s.id as merge_id,
           s.buyer,
           s.shop,
           s.origin,
           s.shop_key,
           (
             select k.id
               from public.conversations k
              where k.merged_into is null
                and k.id <> s.id
                and k.status <> 'ignored'::public.cx_status
                and coalesce(k.kind, 'message') = 'message'
                and k.origin = s.origin
                and lower(btrim(coalesce(k.shop, ''))) = s.shop_key
                and public.cx_normalise_handle(k.customer_handle) = s.buyer
                and not public.cx_is_tiktok_relay(k.customer_handle)
                and not public.cx_is_tiktok_seller_assistant(k.customer_name)
              order by coalesce((select max(m.sent_at) from public.messages m where m.conversation_id = k.id), k.last_message_at) desc nulls last,
                       k.created_at desc
              limit 1
           ) as keep_id
      from src s
  ),
  relay_only as (
    select s.*,
           first_value(s.id) over (
             partition by s.origin, s.shop_key, s.buyer
             order by s.is_assistant, s.activity desc nulls last, s.id
           ) as group_keep
      from src s
     where not exists (select 1 from real_keep r where r.merge_id = s.id and r.keep_id is not null)
  )
  select 'merge'::text,
         r.keep_id,
         r.merge_id,
         r.buyer,
         r.shop,
         'into buyer chat'::text
    from real_keep r
   where r.keep_id is not null
  union all
  select 'merge',
         o.group_keep,
         o.id,
         o.buyer,
         o.shop,
         'relay tickets only'::text
    from relay_only o
   where o.id <> o.group_keep
  union all
  select 'relabel',
         o.id,
         null,
         o.buyer,
         o.shop,
         'no other ticket yet'::text
    from relay_only o
   where o.id = o.group_keep
     and not exists (select 1 from relay_only x where x.group_keep = o.group_keep and x.id <> o.id)
$$;

create or replace function public.cx_apply_tiktok_assistant_merges()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
  rec record;
  before_q jsonb;
  after_q jsonb;
  merged int := 0;
  relabelled int := 0;
begin
  if not public.cx_merge_allowed() then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.id), '[]'::jsonb)
    into before_q
    from public.reply_queue q;

  perform set_config('eggsy.skip_reply_queue', 'on', true);

  for rec in
    select * from public.cx_tiktok_assistant_plan() where action = 'merge' order by keep_id, merge_id
  loop
    perform public.cx_merge_conversations(rec.keep_id, rec.merge_id);
    merged := merged + 1;
  end loop;

  for rec in
    select * from public.cx_tiktok_assistant_plan() where action = 'relabel'
  loop
    update public.conversations
       set customer_handle = '@' || rec.buyer,
           customer_name = case
             when public.cx_is_tiktok_seller_assistant(customer_name) then rec.buyer
             else customer_name
           end,
           updated_at = pg_catalog.now()
     where id = rec.keep_id
       and (
         public.cx_is_tiktok_relay(customer_handle)
         or public.cx_is_tiktok_seller_assistant(customer_name)
       );
    relabelled := relabelled + 1;
  end loop;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.id), '[]'::jsonb)
    into after_q
    from public.reply_queue q;
  if before_q is distinct from after_q then
    raise exception 'reply_queue changed during TikTok assistant merge';
  end if;

  return jsonb_build_object('merged_tickets', merged, 'relabelled', relabelled);
end
$fn$;

revoke all on function public.cx_tiktok_assistant_plan() from public, anon;
revoke all on function public.cx_apply_tiktok_assistant_merges() from public, anon;
grant execute on function public.cx_tiktok_assistant_plan() to authenticated, service_role;
grant execute on function public.cx_apply_tiktok_assistant_merges() to service_role;

notify pgrst, 'reload schema';
