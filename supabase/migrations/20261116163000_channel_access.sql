-- Marketplace lockouts the inbox reads (badges and the "Urgent: locked out" banner).
-- Mirrors the live public.channel_access table. Create-if-not-exists only:
-- applying this does not change rows that are already there.

create table if not exists public.channel_access (
  channel text primary key,
  locked_out boolean not null default false,
  message text,
  detail text,
  locked_since timestamptz,
  last_checked_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.channel_access enable row level security;

drop policy if exists channel_access_read on public.channel_access;
create policy channel_access_read
  on public.channel_access
  for select
  to anon, authenticated
  using (true);

grant select on public.channel_access to anon, authenticated;
grant select, insert, update, delete on public.channel_access to service_role;
