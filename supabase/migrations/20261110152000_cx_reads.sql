-- When each staff member last opened each ticket, so new customer messages show as unread (per person).
create table if not exists public.cx_reads (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_email text not null,
  read_at timestamptz not null default now(),
  primary key (conversation_id, user_email)
);
alter table public.cx_reads enable row level security;
drop policy if exists cx_reads_own on public.cx_reads;
create policy cx_reads_own on public.cx_reads for all to authenticated
  using ((select public.is_lucky_egg_staff()) and user_email = lower((select auth.jwt()) ->> 'email'))
  with check ((select public.is_lucky_egg_staff()) and user_email = lower((select auth.jwt()) ->> 'email'));
grant select, insert, update, delete on public.cx_reads to authenticated;
