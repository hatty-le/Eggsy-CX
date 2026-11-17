-- Orders read from the TikTok Seller Center (or Amazon) panel next to a chat.
-- TikTok's Open API is not approved, so Eggsy's browser read calls cx_upsert_order.
-- Full street addresses are not stored. City and postcode only.

create table if not exists public.cx_orders (
  id uuid primary key default gen_random_uuid(),
  origin public.cx_origin not null,
  shop text,
  platform_order_id text not null,
  status text,
  ordered_at timestamptz,
  is_sample boolean not null default false,
  shipping_status text,
  tracking_number text,
  tracking_carrier text,
  tracking_url text,
  delivered_at timestamptz,
  recipient_city text,
  recipient_postcode text,
  currency text,
  source text,
  pulled_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cx_orders_platform_id_not_blank check (length(btrim(platform_order_id)) > 0),
  constraint cx_orders_origin_order_key unique (origin, platform_order_id)
);

create table if not exists public.cx_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.cx_orders(id) on delete cascade,
  line_no integer not null,
  title text,
  sku text,
  qty integer,
  price numeric,
  currency text,
  constraint cx_order_items_line_key unique (order_id, line_no),
  constraint cx_order_items_line_positive check (line_no > 0)
);

create table if not exists public.cx_order_links (
  order_id uuid not null references public.cx_orders(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  linked_at timestamptz not null default now(),
  primary key (order_id, conversation_id)
);

create index if not exists cx_order_links_conversation_idx
  on public.cx_order_links (conversation_id);

comment on table public.cx_orders is
  'One row per marketplace order (origin + platform order id). City and postcode only; no street address.';
comment on table public.cx_order_items is
  'Line items on a cx_orders row. Replaced on each cx_upsert_order call that includes items.';
comment on table public.cx_order_links is
  'Which conversations show an order. One order can sit on more than one ticket.';

alter table public.cx_orders enable row level security;
alter table public.cx_order_items enable row level security;
alter table public.cx_order_links enable row level security;
alter table public.cx_orders force row level security;
alter table public.cx_order_items force row level security;
alter table public.cx_order_links force row level security;

revoke all on public.cx_orders, public.cx_order_items, public.cx_order_links from public, anon;
grant select on public.cx_orders, public.cx_order_items, public.cx_order_links to authenticated;

drop policy if exists cx_orders_staff_select on public.cx_orders;
create policy cx_orders_staff_select on public.cx_orders
  for select to authenticated using (public.is_lucky_egg_staff());
drop policy if exists cx_order_items_staff_select on public.cx_order_items;
create policy cx_order_items_staff_select on public.cx_order_items
  for select to authenticated using (public.is_lucky_egg_staff());
drop policy if exists cx_order_links_staff_select on public.cx_order_links;
create policy cx_order_links_staff_select on public.cx_order_links
  for select to authenticated using (public.is_lucky_egg_staff());

create or replace function public.cx_upsert_order(p_conversation_id uuid, p_order jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  conv public.conversations%rowtype;
  new_id uuid;
  o_origin public.cx_origin;
  o_id text;
  o_shop text;
  o_currency text;
  city text;
  postcode text;
  item jsonb;
  n int := 0;
  qty int;
  price numeric;
  title text;
  sku text;
begin
  if not (
    public.is_lucky_egg_staff()
    or current_user in ('postgres', 'supabase_admin', 'service_role')
  ) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_order is null or jsonb_typeof(p_order) <> 'object' then
    raise exception 'p_order must be a JSON object';
  end if;
  select * into conv from public.conversations where id = p_conversation_id;
  if not found then
    raise exception 'conversation not found';
  end if;

  o_id := nullif(btrim(p_order->>'platform_order_id'), '');
  if o_id is null then
    o_id := nullif(btrim(p_order->>'order_id'), '');
  end if;
  if o_id is null then
    raise exception 'platform_order_id is required';
  end if;

  if nullif(btrim(p_order->>'origin'), '') is not null then
    o_origin := btrim(p_order->>'origin')::public.cx_origin;
  else
    o_origin := conv.origin;
  end if;
  o_shop := nullif(btrim(coalesce(p_order->>'shop', conv.shop)), '');
  o_currency := nullif(upper(btrim(coalesce(p_order->>'currency', ''))), '');

  -- City and postcode only. Street, name, phone and email are ignored on purpose.
  city := nullif(btrim(coalesce(
    p_order->>'recipient_city',
    p_order#>>'{recipient,city}',
    p_order->>'city'
  )), '');
  postcode := nullif(upper(btrim(coalesce(
    p_order->>'recipient_postcode',
    p_order->>'recipient_zip',
    p_order#>>'{recipient,postcode}',
    p_order#>>'{recipient,zip}',
    p_order->>'postcode',
    p_order->>'zip'
  ))), '');
  if city is not null then city := left(city, 80); end if;
  if postcode is not null then postcode := left(postcode, 16); end if;

  insert into public.cx_orders (
    origin, shop, platform_order_id, status, ordered_at, is_sample,
    shipping_status, tracking_number, tracking_carrier, tracking_url, delivered_at,
    recipient_city, recipient_postcode, currency, source, pulled_at, updated_at
  ) values (
    o_origin,
    o_shop,
    o_id,
    nullif(btrim(p_order->>'status'), ''),
    nullif(btrim(p_order->>'ordered_at'), '')::timestamptz,
    coalesce((p_order->>'is_sample')::boolean, false),
    nullif(btrim(coalesce(p_order->>'shipping_status', '')), ''),
    nullif(btrim(p_order->>'tracking_number'), ''),
    nullif(btrim(coalesce(p_order->>'tracking_carrier', p_order->>'carrier')), ''),
    nullif(btrim(p_order->>'tracking_url'), ''),
    nullif(btrim(p_order->>'delivered_at'), '')::timestamptz,
    city,
    postcode,
    o_currency,
    nullif(btrim(coalesce(p_order->>'source', 'seller_center')), ''),
    now(),
    now()
  )
  on conflict (origin, platform_order_id) do update set
    shop = coalesce(excluded.shop, cx_orders.shop),
    status = coalesce(excluded.status, cx_orders.status),
    ordered_at = coalesce(excluded.ordered_at, cx_orders.ordered_at),
    is_sample = case when jsonb_exists(p_order, 'is_sample') then excluded.is_sample else cx_orders.is_sample end,
    shipping_status = coalesce(excluded.shipping_status, cx_orders.shipping_status),
    tracking_number = coalesce(excluded.tracking_number, cx_orders.tracking_number),
    tracking_carrier = coalesce(excluded.tracking_carrier, cx_orders.tracking_carrier),
    tracking_url = coalesce(excluded.tracking_url, cx_orders.tracking_url),
    delivered_at = coalesce(excluded.delivered_at, cx_orders.delivered_at),
    recipient_city = coalesce(excluded.recipient_city, cx_orders.recipient_city),
    recipient_postcode = coalesce(excluded.recipient_postcode, cx_orders.recipient_postcode),
    currency = coalesce(excluded.currency, cx_orders.currency),
    source = coalesce(excluded.source, cx_orders.source),
    pulled_at = now(),
    updated_at = now()
  returning id into new_id;

  insert into public.cx_order_links (order_id, conversation_id)
  values (new_id, p_conversation_id)
  on conflict (order_id, conversation_id) do nothing;

  if jsonb_exists(p_order, 'items') and jsonb_typeof(p_order->'items') = 'array' then
    delete from public.cx_order_items where cx_order_items.order_id = new_id;
    for item in select value from jsonb_array_elements(p_order->'items')
    loop
      title := nullif(btrim(coalesce(item->>'title', item->>'name', item->>'product')), '');
      sku := nullif(btrim(coalesce(item->>'sku', item->>'seller_sku')), '');
      if title is null and sku is null then
        continue;
      end if;
      n := n + 1;
      begin
        qty := nullif(btrim(coalesce(item->>'qty', item->>'quantity')), '')::integer;
      exception when others then
        qty := null;
      end;
      if qty is null or qty < 1 then qty := 1; end if;
      begin
        price := nullif(btrim(coalesce(item->>'price', item->>'unit_price')), '')::numeric;
      exception when others then
        price := null;
      end;
      insert into public.cx_order_items (order_id, line_no, title, sku, qty, price, currency)
      values (
        new_id, n, left(title, 240), left(sku, 80), qty, price,
        nullif(upper(btrim(coalesce(item->>'currency', o_currency))), '')
      );
    end loop;
  end if;

  return new_id;
end
$$;

comment on function public.cx_upsert_order(uuid, jsonb) is
  'Idempotent order upsert for the Seller Center browser read. Keyed by (origin, platform_order_id). Links the order to the conversation. Does not store a street address.';

revoke all on function public.cx_upsert_order(uuid, jsonb) from public, anon;
grant execute on function public.cx_upsert_order(uuid, jsonb) to authenticated, service_role;
