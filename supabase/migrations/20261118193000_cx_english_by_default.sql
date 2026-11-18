-- Cache an English reading of queued replies that are not messages yet.
-- messages.body_en and suggested_drafts.body_en already hold the same kind of cache.
-- The text that is sent stays in reply_queue.body. Nothing here changes sending.

alter table public.reply_queue
  add column if not exists language text,
  add column if not exists body_en text;

alter table public.reply_queue drop constraint if exists reply_queue_language_iso;
alter table public.reply_queue
  add constraint reply_queue_language_iso check (language is null or language ~ '^[a-z]{2}$');

comment on column public.reply_queue.language is 'ISO 639-1 code of body. en when the queued reply is already English.';
comment on column public.reply_queue.body_en is 'Faithful English translation of body for the inbox. Null when body is already English. Never sent to the customer.';

-- Inbox list: show the cached English line when the latest customer message is not English.
-- Drop first: CREATE OR REPLACE cannot insert columns ahead of preview.
drop view if exists public.cx_latest_inbound;
create view public.cx_latest_inbound
with (security_invoker = true) as
select distinct on (m.conversation_id)
  m.conversation_id,
  m.id as message_id,
  m.language,
  (m.language is not null and m.language <> 'en' and nullif(btrim(coalesce(m.body_en, '')), '') is not null) as preview_is_en,
  left(regexp_replace(split_part(replace(trim(both from
    case
      when m.language is not null and m.language <> 'en' and nullif(btrim(coalesce(m.body_en, '')), '') is not null
        then m.body_en
      else m.body
    end
  ), E'\r', ''), E'\n', 1), '\s+', ' ', 'g'), 160) as preview,
  coalesce(m.platform_sent_at, m.sent_at) as customer_at,
  left((regexp_match(coalesce(m.body_raw, ''), 'You received new messages from\s*:\s*([A-Za-z0-9._]{2,40})', 'i'))[1], 40) as buyer_name
from public.messages m
where m.direction = 'inbound'
  and coalesce(m.body, '') !~ '^\[Summary by Eggsy'
  and length(trim(both from coalesce(m.body, ''))) > 0
order by m.conversation_id, coalesce(m.platform_sent_at, m.sent_at) desc;

comment on view public.cx_latest_inbound is
  'Latest real inbound line (English when a translation is cached), the customer-wrote time, and a TikTok buyer username when the email has one. Respects messages RLS.';

revoke all on public.cx_latest_inbound from public, anon;
grant select on public.cx_latest_inbound to authenticated, service_role;
