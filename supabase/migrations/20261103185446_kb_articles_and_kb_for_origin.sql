-- Eggsy CX knowledge base (staff only)
create table if not exists public.kb_articles (
  id uuid primary key default gen_random_uuid(),
  slug text unique,
  title text not null check (length(btrim(title)) between 3 and 200),
  category text not null check (category in ('Returns & refunds','Faulty, missing & replacements','Shipping & delivery','Orders & cancellations','Products & game rules','Channel rules','Tone & templates','Escalation & routing','Company & contact')),
  body text not null check (length(btrim(body)) > 0),
  applies_to public.cx_origin[],               -- null or empty = all channels
  language text not null default 'en' check (language ~ '^[a-z]{2}$'),
  source_name text not null,
  source_url text,
  source_updated_at date,
  status text not null default 'draft' check (status in ('draft','published')),
  notes text,                                   -- internal: conflicts / caveats, not for customers
  updated_by text,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists kb_articles_status_idx on public.kb_articles (status, category);
create index if not exists kb_articles_applies_idx on public.kb_articles using gin (applies_to);

create or replace function public.kb_articles_touch() returns trigger
language plpgsql set search_path = '' as $$
declare em text := lower((select auth.jwt()) ->> 'email');
begin
  new.updated_at := now();
  if em is not null and em <> '' then new.updated_by := em;
  elsif new.updated_by is null then new.updated_by := 'Eggsy'; end if;
  if new.applies_to is not null and cardinality(new.applies_to) = 0 then new.applies_to := null; end if;
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published') then new.published_at := now();
  elsif new.status = 'draft' then new.published_at := null; end if;
  if tg_op = 'UPDATE' then new.created_at := old.created_at; end if;
  return new;
end $$;
drop trigger if exists kb_articles_touch on public.kb_articles;
create trigger kb_articles_touch before insert or update on public.kb_articles
  for each row execute function public.kb_articles_touch();
revoke execute on function public.kb_articles_touch() from public, anon, authenticated;

alter table public.kb_articles enable row level security;
alter table public.kb_articles force row level security;
revoke all on public.kb_articles from anon, public;
grant select, insert, update on public.kb_articles to authenticated;
drop policy if exists kb_staff_select on public.kb_articles;
drop policy if exists kb_staff_insert on public.kb_articles;
drop policy if exists kb_staff_update on public.kb_articles;
create policy kb_staff_select on public.kb_articles for select to authenticated using ((select public.is_lucky_egg_staff()));
create policy kb_staff_insert on public.kb_articles for insert to authenticated with check ((select public.is_lucky_egg_staff()));
create policy kb_staff_update on public.kb_articles for update to authenticated using ((select public.is_lucky_egg_staff())) with check ((select public.is_lucky_egg_staff()));

-- For the inbox routine: published articles for one channel plus all-channel ones.
-- Channel-specific articles come first. p_language optional: returns that language plus English.
create or replace function public.kb_for_origin(p_origin public.cx_origin, p_language text default null)
returns table (id uuid, title text, category text, body text, applies_to public.cx_origin[], language text,
               source_name text, source_url text, source_updated_at date, channel_specific boolean, updated_at timestamptz)
language sql stable set search_path = '' as $$
  select a.id, a.title, a.category, a.body, a.applies_to, a.language, a.source_name, a.source_url, a.source_updated_at,
         (a.applies_to is not null and cardinality(a.applies_to) > 0) as channel_specific, a.updated_at
    from public.kb_articles a
   where a.status = 'published'
     and (a.applies_to is null or cardinality(a.applies_to) = 0 or p_origin = any (a.applies_to))
     and (p_language is null or a.language = lower(p_language) or a.language = 'en')
   order by channel_specific desc, a.category, a.title
$$;
revoke execute on function public.kb_for_origin(public.cx_origin, text) from public, anon;
grant execute on function public.kb_for_origin(public.cx_origin, text) to authenticated;
comment on function public.kb_for_origin(public.cx_origin, text) is
 'Published KB articles for a channel (applies_to contains the origin) plus all-channel articles (applies_to null/empty). Optional language filter keeps that language plus English. Used by the lucky-egg-inbox-check routine when drafting.';
comment on table public.kb_articles is 'Eggsy CX knowledge base. applies_to null/empty = all channels. Only status=published is used for drafting (kb_for_origin).';
