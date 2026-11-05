create type public.cx_send_status as enum ('queued','sending','sent','failed','cancelled');

create table public.reply_queue (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  body text not null check (length(btrim(body)) between 1 and 20000),
  status public.cx_send_status not null default 'queued',
  origin public.cx_origin,
  shop text,
  to_address text,
  gmail_thread_id text,
  reply_to_message_id text,
  queued_by text,
  queued_at timestamptz not null default now(),
  sending_at timestamptz,
  sent_at timestamptz,
  sent_external_id text,
  message_id uuid references public.messages(id) on delete set null,
  attempts int not null default 0,
  send_error text,
  cancelled_at timestamptz,
  cancelled_by text,
  updated_at timestamptz not null default now()
);
create index reply_queue_status_idx on public.reply_queue (status, queued_at);
create index reply_queue_conversation_idx on public.reply_queue (conversation_id, queued_at);
create index reply_queue_message_idx on public.reply_queue (message_id);

-- Fill platform/threading details from the conversation. For signed-in app users (JWT role authenticated)
-- everything except conversation_id and body is forced, so the browser cannot spoof recipients or statuses.
create or replace function public.reply_queue_before_insert()
returns trigger language plpgsql set search_path = '' as $$
declare c record; is_app boolean := coalesce((select auth.jwt()) ->> 'role', '') = 'authenticated';
begin
  select origin, shop, customer_handle, external_id into c from public.conversations where id = new.conversation_id;
  if not found then raise exception 'conversation not found'; end if;
  if is_app then
    new.status := 'queued'; new.queued_by := lower((select auth.jwt()) ->> 'email'); new.queued_at := now();
    new.sending_at := null; new.sent_at := null; new.sent_external_id := null; new.message_id := null;
    new.attempts := 0; new.send_error := null; new.cancelled_at := null; new.cancelled_by := null;
    new.origin := null; new.shop := null; new.to_address := null; new.gmail_thread_id := null; new.reply_to_message_id := null;
  end if;
  new.origin := coalesce(new.origin, c.origin);
  new.shop := coalesce(new.shop, c.shop);
  if c.origin in ('email_hey','shopify_form','wix_mmc_form') then
    if new.to_address is null and c.customer_handle like '%_@_%.%' then new.to_address := lower(btrim(c.customer_handle)); end if;
    if new.gmail_thread_id is null and c.external_id like 'gmail:%' then new.gmail_thread_id := substr(c.external_id, 7); end if;
    if new.reply_to_message_id is null then
      select substr(m.external_id, 7) into new.reply_to_message_id from public.messages m
       where m.conversation_id = new.conversation_id and m.direction = 'inbound' and m.external_id like 'gmail:%'
       order by m.sent_at desc limit 1;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger reply_queue_before_insert before insert on public.reply_queue for each row execute function public.reply_queue_before_insert();

create or replace function public.reply_queue_before_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    new.cancelled_at := coalesce(new.cancelled_at, now());
    new.cancelled_by := coalesce(new.cancelled_by, lower((select auth.jwt()) ->> 'email'));
  end if;
  return new;
end $$;
create trigger reply_queue_before_update before update on public.reply_queue for each row execute function public.reply_queue_before_update();

alter table public.reply_queue enable row level security;
alter table public.reply_queue force row level security;
revoke all on public.reply_queue from anon, authenticated;
grant select, insert on public.reply_queue to authenticated;
grant update (status) on public.reply_queue to authenticated;

create policy "staff read reply_queue" on public.reply_queue for select to authenticated
  using ((select public.is_lucky_egg_staff()));
create policy "staff queue replies" on public.reply_queue for insert to authenticated
  with check ((select public.is_lucky_egg_staff()) and status = 'queued');
create policy "staff cancel queued replies" on public.reply_queue for update to authenticated
  using ((select public.is_lucky_egg_staff()) and status = 'queued')
  with check ((select public.is_lucky_egg_staff()) and status = 'cancelled');

revoke all on function public.reply_queue_before_insert() from public, anon, authenticated;
revoke all on function public.reply_queue_before_update() from public, anon, authenticated;