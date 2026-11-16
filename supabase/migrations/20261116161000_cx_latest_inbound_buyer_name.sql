-- TikTok notification emails are From "TikTok Shop Seller Assistant".
-- The buyer's username is in the original email. Surface it for the inbox list.

create or replace view public.cx_latest_inbound
with (security_invoker = true) as
select distinct on (m.conversation_id)
  m.conversation_id,
  left(regexp_replace(split_part(replace(trim(both from m.body), E'\r', ''), E'\n', 1), '\s+', ' ', 'g'), 160) as preview,
  coalesce(m.platform_sent_at, m.sent_at) as customer_at,
  left((regexp_match(coalesce(m.body_raw, ''), 'You received new messages from\s*:\s*([A-Za-z0-9._]{2,40})', 'i'))[1], 40) as buyer_name
from public.messages m
where m.direction = 'inbound'
  and coalesce(m.body, '') !~ '^\[Summary by Eggsy'
  and length(trim(both from coalesce(m.body, ''))) > 0
order by m.conversation_id, coalesce(m.platform_sent_at, m.sent_at) desc;

comment on view public.cx_latest_inbound is
  'Latest real inbound line, the customer-wrote time, and a TikTok buyer username when the email has one. Respects messages RLS.';

revoke all on public.cx_latest_inbound from public, anon;
grant select on public.cx_latest_inbound to authenticated, service_role;
