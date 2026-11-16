-- Customer-wrote time for list rows and the Amazon reply clock.
-- TikTok Shop notification emails include the buyer's own clock ("12:19PM, Nov 16").
-- messages.sent_at on those rows is when the notification reached hey@. created_at is when Eggsy imported it.
-- platform_sent_at stores the parsed buyer clock. Other channels keep using sent_at (the platform or mailbox time).

alter table public.messages
  add column if not exists platform_sent_at timestamptz;

comment on column public.messages.platform_sent_at is
  'When the customer wrote, parsed from the platform text when that clock is stored. Null means sent_at is the best time we have. Not the import time.';

create or replace function public.cx_tiktok_customer_time(p_origin text, p_raw text, p_sent_at timestamptz)
returns timestamptz
language plpgsql
stable
set search_path = public
as $$
declare
  m text[];
  tz text;
  hh int;
  mon int;
  yr int;
  cand timestamptz;
  best timestamptz;
begin
  if p_raw is null or p_sent_at is null then return null; end if;
  if p_raw !~* '\d{1,2}:\d{2}\s*[AP]M,' then return null; end if;
  tz := case
    when p_origin = 'tiktok_us' then 'America/Los_Angeles'
    when p_origin = 'tiktok_eu' then 'Europe/Berlin'
    else 'Europe/London'
  end;
  yr := extract(year from p_sent_at at time zone tz)::int;
  for m in
    select regexp_matches(p_raw, '(\d{1,2}):(\d{2})\s*([AP]M),\s*(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{1,2})', 'gi')
  loop
    hh := m[1]::int;
    if upper(m[3]) = 'AM' then
      if hh = 12 then hh := 0; end if;
    elsif hh < 12 then
      hh := hh + 12;
    end if;
    mon := case lower(left(m[4], 3))
      when 'jan' then 1 when 'feb' then 2 when 'mar' then 3 when 'apr' then 4
      when 'may' then 5 when 'jun' then 6 when 'jul' then 7 when 'aug' then 8
      when 'sep' then 9 when 'oct' then 10 when 'nov' then 11 else 12 end;
    begin
      cand := make_timestamptz(yr, mon, m[5]::int, hh, m[2]::int, 0, tz);
    exception when others then
      continue;
    end;
    if cand > p_sent_at + interval '2 days' then
      begin
        cand := make_timestamptz(yr - 1, mon, m[5]::int, hh, m[2]::int, 0, tz);
      exception when others then
        continue;
      end;
    end if;
    if cand > p_sent_at + interval '90 minutes' then
      continue;
    end if;
    if best is null or cand > best then
      best := cand;
    end if;
  end loop;
  return best;
end $$;

revoke all on function public.cx_tiktok_customer_time(text, text, timestamptz) from public, anon;
grant execute on function public.cx_tiktok_customer_time(text, text, timestamptz) to authenticated, service_role;

create or replace function public.cx_set_platform_sent_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  o text;
begin
  if new.direction is distinct from 'inbound'::public.cx_direction then
    return new;
  end if;
  select c.origin::text into o from public.conversations c where c.id = new.conversation_id;
  new.platform_sent_at := public.cx_tiktok_customer_time(o, coalesce(new.body_raw, ''), new.sent_at);
  return new;
exception when others then
  return new;
end $$;

revoke all on function public.cx_set_platform_sent_at() from public, anon, authenticated;

drop trigger if exists messages_platform_sent_at on public.messages;
create trigger messages_platform_sent_at
  before insert or update of body_raw, sent_at, direction, conversation_id
  on public.messages
  for each row execute function public.cx_set_platform_sent_at();

update public.messages m
   set platform_sent_at = public.cx_tiktok_customer_time(c.origin::text, m.body_raw, m.sent_at)
  from public.conversations c
 where c.id = m.conversation_id
   and m.direction = 'inbound'
   and m.body_raw ~* '\d{1,2}:\d{2}\s*[AP]M,';

create or replace view public.cx_latest_inbound
with (security_invoker = true) as
select distinct on (m.conversation_id)
  m.conversation_id,
  left(regexp_replace(split_part(replace(trim(both from m.body), E'\r', ''), E'\n', 1), '\s+', ' ', 'g'), 160) as preview,
  coalesce(m.platform_sent_at, m.sent_at) as customer_at
from public.messages m
where m.direction = 'inbound'
  and coalesce(m.body, '') !~ '^\[Summary by Eggsy'
  and length(trim(both from coalesce(m.body, ''))) > 0
order by m.conversation_id, coalesce(m.platform_sent_at, m.sent_at) desc;

comment on view public.cx_latest_inbound is
  'Latest real inbound line and the customer-wrote time, for the inbox list. Respects messages RLS.';

revoke all on public.cx_latest_inbound from public, anon;
grant select on public.cx_latest_inbound to authenticated, service_role;
