-- Follow-up jobs that need doing after a customer reply: passing game ideas on, logging product faults, and so on.
-- Powers the Actions page. Rows are created by the drafting routine or by staff.
create table if not exists public.cx_followups (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations(id) on delete set null,
  kind text not null default 'other' check (kind in ('game_idea', 'product_fault', 'feedback', 'other')),
  title text not null,
  details text,
  assignees text,
  status text not null default 'open' check (status in ('open', 'done')),
  created_by text,
  created_at timestamptz not null default now(),
  done_at timestamptz,
  done_by text
);
create index if not exists cx_followups_status_idx on public.cx_followups (status, created_at desc);
create unique index if not exists cx_followups_one_open_per_kind on public.cx_followups (conversation_id, kind) where status = 'open';

alter table public.cx_followups enable row level security;
drop policy if exists cx_followups_staff_select on public.cx_followups;
drop policy if exists cx_followups_staff_insert on public.cx_followups;
drop policy if exists cx_followups_staff_update on public.cx_followups;
create policy cx_followups_staff_select on public.cx_followups for select to authenticated using ((select public.is_lucky_egg_staff()));
create policy cx_followups_staff_insert on public.cx_followups for insert to authenticated with check ((select public.is_lucky_egg_staff()));
create policy cx_followups_staff_update on public.cx_followups for update to authenticated using ((select public.is_lucky_egg_staff())) with check ((select public.is_lucky_egg_staff()));
grant select, insert, update on public.cx_followups to authenticated;

-- Open follow-ups count for the menu badge.
CREATE OR REPLACE FUNCTION public.cx_bucket_counts()
 RETURNS json LANGUAGE sql STABLE SET search_path TO ''
AS $function$
  select json_build_object(
    'inbox', count(*) filter (where bucket = 'inbox'),
    'waiting', count(*) filter (where bucket = 'waiting'),
    'resolved', count(*) filter (where bucket = 'resolved'),
    'actions', (select count(*) from public.cx_followups where status = 'open'))
  from public.cx_conversation_state
$function$;
