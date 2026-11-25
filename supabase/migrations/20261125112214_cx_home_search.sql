-- Home-page search across every ticket (Inbox, Waiting, Resolved, Junk).
-- Additive only: a vector helper, a search function, and indexes.
-- Does not replace triggers, cron jobs, or send/queue routines.
-- cx_search_tickets is security definer so the search indexes are used. Under RLS,
-- Postgres will not use an index whose condition is not leakproof, and to_tsvector
-- is not leakproof, so an invoker query seq-scans every message (about a second).
-- The function still returns nothing unless public.is_lucky_egg_staff() is true,
-- which is the same rule as the conversation and message policies. Execute is
-- granted to authenticated only.

create extension if not exists pg_trgm with schema extensions;

-- No SET clause: a function used in an index expression must be immutable,
-- and a SET search_path clause stops Postgres treating it as immutable.
-- Every call inside is schema-qualified instead.
create or replace function public.cx_search_text(p_text text)
returns tsvector
language sql
immutable
parallel safe
as $$
  select pg_catalog.to_tsvector(
    'simple'::pg_catalog.regconfig,
    pg_catalog.regexp_replace(coalesce(p_text, ''::text), '[^[:alnum:]]+', ' ', 'g')
  );
$$;

comment on function public.cx_search_text(text) is
  'Normalise text into a simple-dictionary tsvector for Eggsy ticket search. Punctuation becomes spaces so order numbers and emails match as words.';

revoke all on function public.cx_search_text(text) from public, anon, authenticated;
grant execute on function public.cx_search_text(text) to authenticated;

-- Names and handles: prefix match (lea -> Lea, Leah, Leanne).
create index if not exists conversations_name_search_idx
  on public.conversations using gin (
    public.cx_search_text(coalesce(customer_name, '') || ' ' || coalesce(customer_handle, ''))
  );

-- Order, summary, subject and shop. Short queries use an exact word match
-- against this vector so "lea" does not hit "please" or "least".
-- Channel (the origin enum) is matched separately: casting an enum to text
-- is not immutable, so it cannot sit inside this index expression.
create index if not exists conversations_text_search_idx
  on public.conversations using gin (
    public.cx_search_text(
      coalesce(order_number, '') || ' ' ||
      coalesce(summary, '') || ' ' ||
      coalesce(overview, '') || ' ' ||
      coalesce(subject, '') || ' ' ||
      coalesce(topic, '') || ' ' ||
      coalesce(shop, '')
    )
  );

create index if not exists messages_text_search_idx
  on public.messages using gin (
    public.cx_search_text(coalesce(body, '') || ' ' || coalesce(body_en, ''))
  );

-- Substring match for order ids (a fragment in the middle of a long marketplace id).
create index if not exists conversations_order_number_trgm_idx
  on public.conversations using gin (order_number extensions.gin_trgm_ops);

create index if not exists cx_orders_platform_order_id_trgm_idx
  on public.cx_orders using gin (platform_order_id extensions.gin_trgm_ops);

create or replace function public.cx_search_tickets(p_q text)
returns table (
  conversation_id uuid,
  customer_name text,
  customer_handle text,
  origin text,
  bucket text,
  last_message_at timestamptz,
  snippet text,
  order_number text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_raw text := btrim(coalesce(p_q, ''));
  v_prefix tsquery;
  v_exact tsquery;
  v_short boolean := false;
  v_textq tsquery;
  v_like text;
  v_origins public.cx_origin[];
begin
  if not public.is_lucky_egg_staff() or char_length(v_raw) < 3 then
    return;
  end if;

  select to_tsquery('simple', string_agg(tok || ':*', ' & ' order by tok)),
         to_tsquery('simple', string_agg(tok, ' & ' order by tok)),
         coalesce(bool_or(char_length(tok) < 4), false)
    into v_prefix, v_exact, v_short
  from (
    select tok
    from regexp_split_to_table(lower(v_raw), '[^[:alnum:]]+') as tok
    where char_length(tok) >= 2
  ) s;

  if v_prefix is null then
    return;
  end if;

  -- Three-letter queries match whole words in message and summary text.
  -- Names and handles still use a prefix (lea matches Leah).
  v_textq := case when v_short then v_exact else v_prefix end;
  -- Which channels the words match (amazon -> every amazon_* origin, "amazon de" -> amazon_de).
  select array_agg(e)
    into v_origins
  from unnest(enum_range(null::public.cx_origin)) as e
  where public.cx_search_text(replace(e::text, '_', ' ')) @@ v_prefix
     or strpos(lower(replace(e::text, '_', ' ')), lower(v_raw)) > 0;
  -- % and _ are ILIKE wildcards. A backslash is literal in ILIKE unless ESCAPE is set.
  v_like := replace(replace(v_raw, '%', ''), '_', '');
  if char_length(v_like) < 3 then
    v_like := null;
  else
    v_like := '%' || v_like || '%';
  end if;

  return query
  with name_hits as materialized (
    select c.id
    from public.conversations c
    where c.merged_into is null
      and public.cx_search_text(coalesce(c.customer_name, '') || ' ' || coalesce(c.customer_handle, '')) @@ v_prefix
  ),
  text_hits as materialized (
    select c.id
    from public.conversations c
    where c.merged_into is null
      and public.cx_search_text(
        coalesce(c.order_number, '') || ' ' ||
        coalesce(c.summary, '') || ' ' ||
        coalesce(c.overview, '') || ' ' ||
        coalesce(c.subject, '') || ' ' ||
        coalesce(c.topic, '') || ' ' ||
        coalesce(c.shop, '')
      ) @@ v_textq
  ),
  origin_hits as materialized (
    select c.id
    from public.conversations c
    where c.merged_into is null
      and v_origins is not null
      and c.origin = any (v_origins)
  ),
  order_hits as materialized (
    select c.id
    from public.conversations c
    where c.merged_into is null
      and v_like is not null
      and c.order_number ilike v_like
    union
    select l.conversation_id
    from public.cx_order_links l
    join public.cx_orders o on o.id = l.order_id
    join public.conversations c on c.id = l.conversation_id
    where c.merged_into is null
      and v_like is not null
      and o.platform_order_id ilike v_like
  ),
  msg_recent as materialized (
    select m.conversation_id as id,
           m.sent_at,
           substr(
             regexp_replace(coalesce(m.body, m.body_en, ''), '[[:space:]]+', ' ', 'g'),
             greatest(1, strpos(
               lower(regexp_replace(coalesce(m.body, m.body_en, ''), '[[:space:]]+', ' ', 'g')),
               lower(v_raw)
             ) - 50),
             160
           ) as msg
    from public.messages m
    join public.conversations c on c.id = m.conversation_id
    where c.merged_into is null
      and m.direction::text in ('inbound', 'outbound')
      and public.cx_search_text(coalesce(m.body, '') || ' ' || coalesce(m.body_en, '')) @@ v_textq
    order by m.sent_at desc
    limit 80
  ),
  msg_hits as (
    select distinct on (r.id) r.id, r.msg
    from msg_recent r
    order by r.id, r.sent_at desc
  ),
  ids as (
    select name_hits.id from name_hits
    union
    select text_hits.id from text_hits
    union
    select origin_hits.id from origin_hits
    union
    select order_hits.id from order_hits
    union
    select msg_hits.id from msg_hits
  ),
  ranked as (
    select c.id,
           c.customer_name,
           c.customer_handle,
           c.origin::text as origin,
           c.status::text as status,
           c.last_message_at,
           c.overview,
           c.summary,
           c.subject,
           c.order_number,
           mh.msg,
           case
             when lower(btrim(coalesce(c.customer_name, ''))) = lower(v_raw) then 0
             when strpos(lower(coalesce(c.customer_name, '')), lower(v_raw)) = 1 then 1
             when public.cx_search_text(coalesce(c.customer_name, '')) @@ v_prefix then 2
             when public.cx_search_text(coalesce(c.customer_handle, '')) @@ v_prefix then 3
             when exists (select 1 from order_hits o where o.id = c.id)
               or (v_like is not null and coalesce(c.order_number, '') ilike v_like) then 4
             when (v_origins is not null and c.origin = any (v_origins))
               or public.cx_search_text(coalesce(c.shop, '')) @@ v_prefix then 5
             when exists (select 1 from text_hits t where t.id = c.id) then 6
             else 7
           end as hit_rank
    from ids
    join public.conversations c on c.id = ids.id
    left join msg_hits mh on mh.id = c.id
  ),
  top as materialized (
    select *
    from ranked
    order by ranked.hit_rank, ranked.last_message_at desc nulls last, ranked.id
    limit 25
  )
  select top.id,
         top.customer_name,
         top.customer_handle,
         top.origin,
         coalesce(
           st.bucket,
           case top.status
             when 'ignored' then 'junk'
             when 'resolved' then 'resolved'
             when 'awaiting_customer' then 'waiting'
             else 'inbox'
           end
         ),
         top.last_message_at,
         left(regexp_replace(coalesce(
           case when top.hit_rank >= 7 then nullif(btrim(top.msg), '') end,
           nullif(btrim(top.overview), ''),
           nullif(btrim(top.summary), ''),
           nullif(btrim(top.subject), ''),
           ''
         ), '[[:space:]]+', ' ', 'g'), 180),
         coalesce(
           nullif(btrim(top.order_number), ''),
           (select o.platform_order_id
            from public.cx_order_links l
            join public.cx_orders o on o.id = l.order_id
            where l.conversation_id = top.id
            order by l.linked_at desc
            limit 1)
         )
  from top
  -- One pass over the folder view for this page of hits. A plain equijoin
  -- re-ran the view once per row (about a second). Matching the id list keeps it to one pass.
  left join public.cx_conversation_state st
    on st.conversation_id = any (array(select picked.id from top picked))
   and st.conversation_id = top.id
  order by top.hit_rank, top.last_message_at desc nulls last, top.id;
end;
$$;

comment on function public.cx_search_tickets(text) is
  'Home search across every conversation, whatever folder it is in. Matches customer name and handle, email, order number, channel, summary and message text. Security definer so the text indexes can be used; returns no rows unless the caller is @luckyegg.co staff.';

revoke all on function public.cx_search_tickets(text) from public, anon, authenticated;
grant execute on function public.cx_search_tickets(text) to authenticated;

analyze public.conversations;
analyze public.messages;
analyze public.cx_orders;
