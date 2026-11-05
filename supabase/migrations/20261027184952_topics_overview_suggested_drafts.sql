alter table public.conversations
  add column if not exists topic text,
  add column if not exists overview text;
alter table public.conversations drop constraint if exists conversations_topic_check;
alter table public.conversations add constraint conversations_topic_check check (topic is null or topic in (
 'Return request','Refund request','Shipping / where''s my order','Damaged or faulty','Missing parts','Replacement',
 'Product / gameplay question','Order change / cancellation','Address issue','Wholesale / B2B','Complaint','Feedback / praise','Other'));
alter table public.conversations drop constraint if exists conversations_overview_len;
alter table public.conversations add constraint conversations_overview_len check (overview is null or char_length(overview) <= 160);
comment on column public.conversations.topic is 'Ticket topic from a fixed list (see README).';
comment on column public.conversations.overview is 'One-line plain-English summary of the ticket (no customer text).';

create table if not exists public.suggested_drafts (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 10000),
  body_en text,
  language text,
  author text not null default 'Eggsy',
  drafted_at timestamptz not null default now(),
  superseded boolean not null default false,
  superseded_at timestamptz,
  external_id text,
  created_at timestamptz not null default now()
);
create unique index if not exists suggested_drafts_one_current on public.suggested_drafts(conversation_id) where not superseded;
create index if not exists suggested_drafts_conv_idx on public.suggested_drafts(conversation_id, drafted_at desc);
alter table public.suggested_drafts enable row level security;
alter table public.suggested_drafts force row level security;
drop policy if exists "staff read drafts" on public.suggested_drafts;
create policy "staff read drafts" on public.suggested_drafts for select to authenticated using ((select public.is_lucky_egg_staff()));
revoke all on public.suggested_drafts from anon, authenticated;
grant select on public.suggested_drafts to authenticated;
