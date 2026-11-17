-- MMC inbox flag. Ignored tickets stay untagged: junk, corporate, colleague-forward
-- and Marty-forward filters decide that before this classifier runs.
-- A catalogue title that only appears with order, delivery or refund wording stays ordinary.
-- Sketchy Suspects is not an MMC title.

alter table public.conversations
  add column if not exists is_mmc boolean not null default false;

comment on column public.conversations.is_mmc is
  'Murder Mystery Cases inbox. Set by cx_refresh_conversation_mmc. Ignored tickets are never tagged.';

create index if not exists conversations_is_mmc_idx
  on public.conversations (is_mmc)
  where is_mmc;

create or replace function public.cx_is_mmc(
  p_status text,
  p_origin text,
  p_subject text,
  p_shop text,
  p_from text,
  p_text text
) returns boolean
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  hay text;
  cleaned text;
  sketchy boolean;
  toyfair boolean;
  rule_a boolean;
  rule_b boolean;
  title_other boolean;
  title_square boolean;
  has_title boolean;
  mmc_phrase boolean;
  play boolean;
  commerce boolean;
begin
  if coalesce(p_status, '') = 'ignored' then
    return false;
  end if;

  hay := lower(
    coalesce(p_subject, '') || E'\n' ||
    coalesce(p_shop, '') || E'\n' ||
    coalesce(p_from, '') || E'\n' ||
    coalesce(p_text, '')
  );

  sketchy := hay ~ 'sketchy suspects';
  toyfair := hay ~ '(toy fair|spielwarenmesse)';
  rule_a := p_origin = 'wix_mmc_form'
    or (hay ~ 'no-reply@crm\.wix\.com' and hay ~ 'notification from murder mystery cases');

  cleaned := regexp_replace(
    hay,
    '(post|zip|bar|batch|discount|promo|product|country|area|sku|gift|coupon|verification|tracking|order|postal|security)[[:space:]-]*codes?',
    ' ',
    'g'
  );
  cleaned := regexp_replace(cleaned, 'hinterl(a|ä)ss\w*|hinten', ' ', 'g');

  rule_b := cleaned ~ '[[:<:]](phones?|laptops?|mobiles?|iphones?|smartphones?)[[:>:]].{0,40}[[:<:]](passcodes?|passwords?|pass-codes?|codes?)[[:>:]]'
    or cleaned ~ '[[:<:]](passcodes?|passwords?|pass-codes?|codes?)[[:>:]].{0,40}[[:<:]](phones?|laptops?|mobiles?|iphones?|smartphones?)[[:>:]]'
    or cleaned ~ '[[:<:]]alibis?[[:>:]]'
    or cleaned ~ '[[:<:]]motives?[[:>:]]'
    or cleaned ~ '[[:<:]]envelope[[:space:]]*([0-9]|one|two|three|four|five)'
    or cleaned ~ 'the boss'
    or cleaned ~ 'who did it|whodunnit|whodunit|who is the killer|who''s the killer|who was the killer|who is the murderer';

  title_other := cleaned ~ 'death[[:space:]]+(at|on|in)[[:space:]]+area[[:space:]]*5[12]|[[:<:]]area[[:space:]]*5[12][[:>:]]|murder[[:space:]]+in[[:space:]]+the[[:space:]]+vatican|[[:<:]]vatican[[:>:]]|eiffel[[:space:]]+tower|mount[[:space:]]+(e|a)verest|dublin''?s?[[:space:]]+castle|death[[:space:]]+of[[:space:]]+an[[:space:]]+influencer|white[[:space:]]+house|murder[[:space:]]+of[[:space:]]+an[[:space:]]+activist|buckingham[[:space:]]+palace|wirth[[:space:]]+circus|death[[:space:]]+of[[:space:]]+an[[:space:]]+artist|fpi[[:space:]]+mystery';
  title_square := cleaned ~ 'death[[:space:]]+(at|on|in)[[:space:]]+times?[[:space:]]+squares?|[[:<:]]times?[[:space:]]+squares?[[:>:]]';
  has_title := title_other or (title_square and not toyfair);
  mmc_phrase := cleaned ~ '[[:<:]]mmc[[:>:]]|murder[[:space:]]+mystery[[:space:]]+cases?';
  play := cleaned ~ '[[:<:]]evidence[[:>:]]|[[:<:]]clues?[[:>:]]|[[:<:]]cctv[[:>:]]|[[:<:]]misprints?[[:>:]]|[[:<:]]mistakes?[[:>:]]|missing[[:space:]]+(evidence|clues?|documents?)|[[:<:]]hints?[[:>:]]|[[:<:]]solutions?[[:>:]]|newspaper|[[:<:]]stage[[:space:]]*[0-9]';
  commerce := cleaned ~ '[[:<:]](refund|refunded|refunds|reimburse|reimbursement|undeliverable|undelivered|delivery|delivered|deliveries|shipping|shipment)[[:>:]]|(did not|didn''t|has not|hasn''t|not|never)[[:space:]]+arrive[d]?|[[:<:]](package|packages|parcel|parcels)[[:>:]]|(my|your|the|this)[[:space:]]+order|order[[:space:]]*(#|number)|[[:<:]](cancel|cancelled|canceled|cancellation)[[:>:]]|[[:<:]](lieferung|geliefert|versand|paket|stornierung|storniert|terugbetaling|bezorging|bezorgd|verzending|remboursement|livraison|colis|rimborso|consegna|pacco|reembolso|entrega|paquete)[[:>:]]|nicht[[:space:]]+(angekommen|geliefert)|niet[[:space:]]+(aangekomen|geleverd|bezorgd)';

  if sketchy and not has_title and not mmc_phrase and not rule_a then
    return false;
  end if;

  return rule_a
    or (rule_b and not (sketchy and not has_title and not mmc_phrase))
    or ((has_title or mmc_phrase) and play and not (sketchy and not has_title))
    or (has_title and not commerce and not sketchy);
end
$fn$;

comment on function public.cx_is_mmc(text, text, text, text, text, text) is
  'Shared MMC classifier. False for ignored tickets, Sketchy Suspects, and a case name that only appears with order, delivery or refund wording.';

revoke all on function public.cx_is_mmc(text, text, text, text, text, text) from public, anon;
grant execute on function public.cx_is_mmc(text, text, text, text, text, text) to authenticated, service_role;

create or replace function public.cx_refresh_conversation_mmc(p_id uuid)
returns boolean
language plpgsql
volatile
set search_path = ''
as $fn$
declare
  r public.conversations%rowtype;
  txt text;
  mmc_flag boolean;
begin
  select * into r from public.conversations where id = p_id;
  if not found then
    return false;
  end if;

  if r.status::text = 'ignored' then
    if r.is_mmc then
      update public.conversations set is_mmc = false where id = p_id;
    end if;
    return false;
  end if;

  select string_agg(
    coalesce(m.author, '') || ' ' ||
    coalesce(m.body, '') || ' ' ||
    coalesce(m.body_en, '') || ' ' ||
    coalesce(m.body_raw, ''),
    E'\n'
  )
    into txt
  from public.messages m
  where m.conversation_id = p_id
    and m.direction::text = 'inbound';

  mmc_flag := public.cx_is_mmc(r.status::text, r.origin::text, r.subject, r.shop, r.customer_handle, txt);
  if r.is_mmc is distinct from mmc_flag then
    update public.conversations set is_mmc = mmc_flag where id = p_id;
  end if;
  return mmc_flag;
end
$fn$;

comment on function public.cx_refresh_conversation_mmc(uuid) is
  'Recompute conversations.is_mmc from the subject, shop and inbound messages. Ignored tickets are cleared.';

revoke all on function public.cx_refresh_conversation_mmc(uuid) from public, anon;
grant execute on function public.cx_refresh_conversation_mmc(uuid) to authenticated, service_role;

create or replace function public.cx_messages_tag_mmc()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  if new.direction::text = 'inbound' then
    perform public.cx_refresh_conversation_mmc(new.conversation_id);
  end if;
  return new;
end
$fn$;

drop trigger if exists messages_tag_mmc on public.messages;
create trigger messages_tag_mmc
  after insert on public.messages
  for each row execute function public.cx_messages_tag_mmc();

create or replace function public.cx_conversations_mmc_on_status()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  if new.status is distinct from old.status then
    perform public.cx_refresh_conversation_mmc(new.id);
  end if;
  return new;
end
$fn$;

drop trigger if exists conversations_mmc_on_status on public.conversations;
create trigger conversations_mmc_on_status
  after update of status on public.conversations
  for each row execute function public.cx_conversations_mmc_on_status();

revoke all on function public.cx_messages_tag_mmc() from public, anon, authenticated;
revoke all on function public.cx_conversations_mmc_on_status() from public, anon, authenticated;

-- Backfill every existing conversation. New imports are tagged by the message trigger
-- (marketplace, Meta, Shopify and Wix forms included) after junk filters have skipped a row.
do $backfill$
declare
  r record;
begin
  for r in select id from public.conversations loop
    perform public.cx_refresh_conversation_mmc(r.id);
  end loop;
end
$backfill$;
