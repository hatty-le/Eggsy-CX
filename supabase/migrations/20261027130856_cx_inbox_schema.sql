create type public.cx_origin as enum ('email_hey','shopify_form','wix_mmc_form','tiktok_uk','tiktok_eu','tiktok_us','amazon_uk','amazon_us','amazon_de','amazon_fr','amazon_it','amazon_es','amazon_nl','amazon_se','amazon_pl','amazon_be','amazon_other','walmart','facebook','instagram');
create type public.cx_status as enum ('open','awaiting_approval','awaiting_customer','resolved','ignored');
create type public.cx_direction as enum ('inbound','outbound','draft','note');

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  origin public.cx_origin not null,
  shop text,
  customer_name text,
  customer_handle text,
  subject text,
  order_number text,
  status public.cx_status not null default 'open',
  summary text,
  external_id text,
  last_message_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (origin, external_id)
);
create index conversations_last_message_idx on public.conversations (last_message_at desc nulls last);
create index conversations_origin_idx on public.conversations (origin);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  direction public.cx_direction not null,
  author text,
  body text not null default '',
  sent_at timestamptz not null,
  external_id text,
  external_thread_id text,
  created_at timestamptz not null default now(),
  unique (conversation_id, external_id)
);
create index messages_conversation_idx on public.messages (conversation_id, sent_at);

-- helper: is the caller a signed-in @luckyegg.co user?
create or replace function public.is_lucky_egg_staff() returns boolean
language sql stable security invoker set search_path = ''
as $$ select coalesce(lower((select auth.jwt()) ->> 'email') like '%@luckyegg.co', false)
            and coalesce(((select auth.jwt()) ->> 'role') = 'authenticated', false) $$;

-- keep conversations.last_message_at in step with messages
create or replace function public.touch_conversation() returns trigger
language plpgsql security definer set search_path = ''
as $$ begin
  update public.conversations c
     set last_message_at = greatest(coalesce(c.last_message_at, new.sent_at), new.sent_at),
         updated_at = now()
   where c.id = new.conversation_id;
  return new;
end $$;
revoke execute on function public.touch_conversation() from public, anon, authenticated;
create trigger messages_touch_conversation after insert on public.messages
  for each row execute function public.touch_conversation();

alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.conversations force row level security;
alter table public.messages force row level security;

revoke all on public.conversations, public.messages from anon;
grant select, insert, update on public.conversations, public.messages to authenticated;

create policy "staff read conversations" on public.conversations for select to authenticated using ((select public.is_lucky_egg_staff()));
create policy "staff update conversations" on public.conversations for update to authenticated using ((select public.is_lucky_egg_staff())) with check ((select public.is_lucky_egg_staff()));
create policy "staff insert conversations" on public.conversations for insert to authenticated with check ((select public.is_lucky_egg_staff()));
create policy "staff read messages" on public.messages for select to authenticated using ((select public.is_lucky_egg_staff()));
create policy "staff insert messages" on public.messages for insert to authenticated with check ((select public.is_lucky_egg_staff()));