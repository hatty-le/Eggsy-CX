-- Five reply types Hatty greenlit for auto-send (23 Nov 2026).
-- Both drafters (author Eggsy, and the batch drafter author Claude) read the
-- published knowledge articles through kb_for_origin and save with cx_save_draft.
-- This migration does not rewrite an existing draft and does not queue a reply.
-- The new pre-queue check applies only to drafts saved after auto_send_greenlit_from.

INSERT INTO public.cx_settings (key, value, updated_at, updated_by)
VALUES (
  'auto_send_greenlit_types',
  jsonb_build_object(
    'tracking_update', true,
    'address_confirmation', true,
    'wholesale_holding', true,
    'thank_you', true,
    'junk_decision', true
  ),
  now(),
  'Eggsy'
)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.cx_settings (key, value, updated_at, updated_by)
VALUES ('auto_send_greenlit_from', to_jsonb(now()), now(), 'Eggsy')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE public.suggested_drafts
  ADD COLUMN IF NOT EXISTS reply_type text,
  ADD COLUMN IF NOT EXISTS reply_facts jsonb;

COMMENT ON COLUMN public.suggested_drafts.reply_type IS
  'Greenlit auto-send type the drafter recorded: tracking_update, address_confirmation, wholesale_holding, thank_you, or junk_decision. Null on older drafts and on every other type.';
COMMENT ON COLUMN public.suggested_drafts.reply_facts IS
  'Lookup the drafter recorded for a greenlit type. Tracking and address replies need order_found. Address replies also need shipped and address_matches. No street address is stored.';

CREATE OR REPLACE FUNCTION public.cx_greenlit_type_enabled(p_type text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO ''
AS $fn$
  SELECT CASE
    WHEN p_type IS NULL THEN false
    WHEN NOT EXISTS (SELECT 1 FROM public.cx_settings WHERE key = 'auto_send_greenlit_types') THEN true
    ELSE coalesce((SELECT (value ->> p_type)::boolean FROM public.cx_settings WHERE key = 'auto_send_greenlit_types'), false)
  END
$fn$;

COMMENT ON FUNCTION public.cx_greenlit_type_enabled(text) IS
  'True when that greenlit type is switched on in cx_settings key auto_send_greenlit_types. Set the type to false to send it to Gaps instead of auto-send.';

CREATE OR REPLACE FUNCTION public.cx_greenlit_customer_text(p_body text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $fn$
  SELECT btrim(regexp_replace(coalesce(p_body, ''), '\[[^\]]*\]', '', 'g'))
$fn$;

CREATE OR REPLACE FUNCTION public.cx_shipping_is_exception(p_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $fn$
  SELECT coalesce(p_status, '') ~* '\m(delivered|lost|failed|failure|returned|exception|undeliverable)\M'
     AND coalesce(p_status, '') !~* '\m(not|awaiting|pending|unfulfilled|unshipped|in transit|in_transit)\M'
$fn$;

CREATE OR REPLACE FUNCTION public.cx_shipping_is_unshipped(p_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $fn$
  SELECT coalesce(p_status, '') ~* '(unfulfilled|unshipped|not shipped|not yet shipped|awaiting fulfilment|awaiting fulfillment|\mpending\M|on hold)'
     AND NOT public.cx_shipping_is_exception(p_status)
     AND coalesce(p_status, '') !~* '\m(fulfilled|shipped|in transit|in_transit|collected|out for delivery|delivered)\M'
$fn$;

-- Text-only half of the pre-queue check. Null means the words themselves are allowed.
CREATE OR REPLACE FUNCTION public.cx_greenlit_text_problem(p_type text, p_body text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $fn$
DECLARE
  b text := public.cx_greenlit_customer_text(p_body);
BEGIN
  IF p_type = 'tracking_update' THEN
    IF b ~* '\m(refund|replacement|compensate|compensation|goodwill)\M' THEN
      RETURN 'tracking_remedy';
    END IF;
    IF b ~* '\m(delivery date|dispatch date|arrival date)\M' THEN
      RETURN 'tracking_delivery_date';
    END IF;
    IF b ~* '\mby\s+\d{1,2}(st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)' THEN
      RETURN 'tracking_delivery_date';
    END IF;
    IF b ~* '(deliver|arriv|dispatch|eta).{0,70}(\d{1,2}(st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\m(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\M)' THEN
      RETURN 'tracking_delivery_date';
    END IF;
    RETURN NULL;
  ELSIF p_type = 'address_confirmation' THEN
    IF b ~* '((address|postcode|post code|zip).{0,50}\m(changed|updated)\M|\m(changed|updated)\M.{0,50}(address|postcode|post code|zip))' THEN
      RETURN 'address_change_unrecorded';
    END IF;
    RETURN NULL;
  ELSIF p_type = 'wholesale_holding' THEN
    IF b ~ '[£$€]' THEN
      RETURN 'wholesale_commercial_terms';
    END IF;
    IF b ~* '(\m(price|cost|priced|pricing|rrp)\M.{0,20}\d|\d.{0,16}\m(price|cost|gbp|usd|eur)\M)' THEN
      RETURN 'wholesale_commercial_terms';
    END IF;
    IF b ~* '\m(minimum|moq|discount|terms)\M' THEN
      RETURN 'wholesale_commercial_terms';
    END IF;
    RETURN NULL;
  ELSIF p_type = 'thank_you' THEN
    IF b ~* '(\m(we will|i will)\M|we''ll|i''ll|we have passed|we''ve passed|we’ve passed|\mpromise\M|\mrefund\M|\mreplacement\M|\mdiscount\M|\msend you\M)' THEN
      RETURN 'thank_you_promise';
    END IF;
    RETURN NULL;
  END IF;
  RETURN NULL;
END
$fn$;

CREATE OR REPLACE FUNCTION public.cx_draft_order_lookup(p_conversation uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'origin', o.origin,
           'platform_order_id', o.platform_order_id,
           'status', o.status,
           'shipping_status', o.shipping_status,
           'tracking_number', o.tracking_number,
           'tracking_carrier', o.tracking_carrier,
           'delivered_at', o.delivered_at,
           'recipient_city', o.recipient_city,
           'recipient_postcode', o.recipient_postcode,
           'is_sample', o.is_sample,
           'source', o.source
         ) ORDER BY o.updated_at DESC), '[]'::jsonb)
    FROM public.cx_orders o
    JOIN public.cx_order_links l ON l.order_id = o.id
   WHERE l.conversation_id = p_conversation
$fn$;

COMMENT ON FUNCTION public.cx_draft_order_lookup(uuid) IS
  'Read-only marketplace order already stored for a ticket. City and postcode only. Website orders are looked up with the cx-actions lookup_order action, which is a read-only Shopify Admin query.';

REVOKE ALL ON FUNCTION public.cx_draft_order_lookup(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cx_draft_order_lookup(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.cx_classify_greenlit_reply(p_conversation uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  topic text;
  subject text;
  flag text;
  status text;
  inbound text;
  hay text;
BEGIN
  SELECT c.topic, c.subject, c.flag, c.status::text
    INTO topic, subject, flag, status
    FROM public.conversations c
   WHERE c.id = p_conversation;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT m.body INTO inbound
    FROM public.messages m
   WHERE m.conversation_id = p_conversation
     AND m.direction = 'inbound'
     AND coalesce(m.body, '') !~ '^\[Summary by Eggsy'
   ORDER BY m.sent_at DESC
   LIMIT 1;
  inbound := coalesce(inbound, '');
  hay := lower(coalesce(topic, '') || ' ' || coalesce(subject, '') || ' ' || inbound);

  IF status = 'ignored'
     OR coalesce(topic, '') ~* '(affiliate|spam|newsletter|sourcing)'
     OR coalesce(flag, '') ~* '\m(spam|junk|phishing)\M' THEN
    RETURN 'junk_decision';
  END IF;

  IF coalesce(topic, '') IN (
       'Replacement', 'Refund request', 'Return request', 'Missing parts',
       'Damaged or faulty', 'Product / gameplay question', 'Order change / cancellation', 'Complaint'
     )
     OR hay ~ '\m(refund|replacement|missing part|missing piece|damaged|faulty|broken|cancel)\M' THEN
    RETURN NULL;
  END IF;

  IF coalesce(topic, '') = 'Wholesale / B2B'
     OR hay ~ '\m(wholesale|b2b|reseller|stockist|trade account|distributor)\M' THEN
    RETURN 'wholesale_holding';
  END IF;

  IF coalesce(topic, '') = 'Shipping / where''s my order'
     OR (
       coalesce(topic, '') NOT IN ('Feedback / praise', 'Address issue', 'Wholesale / B2B')
       AND hay ~ 'where''?s my (order|parcel|package)|where is my (order|parcel|package)|\btracking\b|has it (shipped|been dispatched)|order status'
     ) THEN
    RETURN 'tracking_update';
  END IF;

  IF (
       coalesce(topic, '') = 'Address issue'
       OR hay ~ '(confirm|check|correct|verify).{0,40}(address|postcode|post code|\mzip\M)|(address|postcode).{0,30}(correct|right|confirm)'
     )
     AND hay !~ '(change my address|changed my address|wrong address|\bi moved\M|\bwe moved\M)' THEN
    RETURN 'address_confirmation';
  END IF;

  IF coalesce(topic, '') = 'Feedback / praise'
     OR (
       coalesce(topic, '') IN ('', 'Other')
       AND inbound ~* '\m(thank you|thanks|cheers|much appreciated|love (it|this|the game)|no further|that''s all|all sorted)\M'
       AND inbound !~ '\?'
       AND char_length(inbound) < 800
     ) THEN
    IF inbound ~* '\m(wrong|incorrect|error|bug|mistake|broken|fault|missing)\M' THEN
      RETURN NULL;
    END IF;
    RETURN 'thank_you';
  END IF;

  RETURN NULL;
END
$fn$;

CREATE OR REPLACE FUNCTION public.cx_greenlit_creator_or_sample(p_conversation uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.conversations c
     WHERE c.id = p_conversation
       AND (
         coalesce(c.flag, '') ~* '(creator|influencer|\mugc\M|ad[- ]?code|spark|free sample|sample request)'
         OR coalesce(c.topic, '') ~* '(creator|influencer|sample)'
       )
  )
  OR EXISTS (
    SELECT 1 FROM public.cx_orders o
      JOIN public.cx_order_links l ON l.order_id = o.id
     WHERE l.conversation_id = p_conversation AND o.is_sample
  )
  OR EXISTS (
    SELECT 1 FROM public.cx_actions a
     WHERE a.conversation_id = p_conversation AND a.type = 'sample'
  )
  OR EXISTS (
    SELECT 1 FROM public.messages m
     WHERE m.conversation_id = p_conversation
       AND m.direction = 'inbound'
       AND m.body ~* '(free sample|\mugc\M|ad code|spark code|influencer|creator code)'
  )
$fn$;

CREATE OR REPLACE FUNCTION public.cx_greenlit_address_change_recorded(p_conversation uuid, p_facts jsonb)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
  SELECT coalesce(p_facts->>'address_changed', '') IN ('true', 't', 'yes')
      OR EXISTS (
        SELECT 1 FROM public.cx_actions a
         WHERE a.conversation_id = p_conversation
           AND (
             coalesce(a.details->>'address_changed', '') IN ('true', 't', 'yes')
             OR coalesce(a.details->>'description', '') ~* 'address (has been |was )?changed'
           )
      )
$fn$;

CREATE OR REPLACE FUNCTION public.cx_greenlit_order_state(p_conversation uuid, p_facts jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  found_orders boolean := false;
  any_exception boolean := false;
  all_unshipped boolean := true;
  saw boolean := false;
  any_sample boolean := false;
  status text;
  rec record;
  facts jsonb := coalesce(p_facts, '{}'::jsonb);
BEGIN
  FOR rec IN
    SELECT o.status, o.shipping_status, o.is_sample
      FROM public.cx_orders o
      JOIN public.cx_order_links l ON l.order_id = o.id
     WHERE l.conversation_id = p_conversation
  LOOP
    saw := true;
    found_orders := true;
    status := coalesce(nullif(rec.shipping_status, ''), rec.status, '');
    IF public.cx_shipping_is_exception(status) THEN
      any_exception := true;
    END IF;
    IF NOT public.cx_shipping_is_unshipped(status) THEN
      all_unshipped := false;
    END IF;
    IF rec.is_sample THEN
      any_sample := true;
    END IF;
  END LOOP;
  IF NOT saw THEN
    all_unshipped := false;
  END IF;

  IF facts ? 'order_found' THEN
    found_orders := facts->>'order_found' IN ('true', 't', 'yes');
  END IF;
  IF facts ? 'exception' THEN
    any_exception := facts->>'exception' IN ('true', 't', 'yes');
  ELSIF facts ? 'shipping_status' THEN
    any_exception := public.cx_shipping_is_exception(facts->>'shipping_status');
    IF found_orders IS NOT TRUE AND facts->>'shipping_status' <> '' THEN
      found_orders := true;
    END IF;
  END IF;
  IF facts ? 'shipped' THEN
    all_unshipped := facts->>'shipped' IN ('false', 'f', 'no');
  ELSIF facts ? 'shipping_status' AND public.cx_shipping_is_unshipped(facts->>'shipping_status') THEN
    all_unshipped := true;
  END IF;

  RETURN jsonb_build_object(
    'found', found_orders,
    'exception', any_exception,
    'unshipped', all_unshipped AND found_orders AND NOT any_exception,
    'sample', any_sample
  );
END
$fn$;

-- Returns a hold code, or null when this draft is not blocked by a greenlit rule.
-- p_force true ignores the "new drafts only" cutoff and is for the dry run.
CREATE OR REPLACE FUNCTION public.cx_greenlit_prequeue_block(
  p_conversation uuid,
  p_body text,
  p_force boolean DEFAULT false
) RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  stored_type text;
  stored_facts jsonb;
  drafted_at timestamptz;
  cutoff timestamptz;
  reply_type text;
  text_problem text;
  state jsonb;
  raw_cutoff text;
BEGIN
  SELECT d.reply_type, d.reply_facts, d.drafted_at
    INTO stored_type, stored_facts, drafted_at
    FROM public.suggested_drafts d
   WHERE d.conversation_id = p_conversation
     AND NOT d.superseded
   ORDER BY d.drafted_at DESC
   LIMIT 1;

  IF NOT coalesce(p_force, false) THEN
    SELECT value #>> '{}' INTO raw_cutoff
      FROM public.cx_settings WHERE key = 'auto_send_greenlit_from';
    cutoff := nullif(raw_cutoff, '')::timestamptz;
    IF stored_type IS NULL AND drafted_at IS NOT NULL AND cutoff IS NOT NULL AND drafted_at < cutoff THEN
      RETURN NULL;
    END IF;
  END IF;

  reply_type := stored_type;
  IF reply_type IS NULL OR reply_type NOT IN (
       'tracking_update', 'address_confirmation', 'wholesale_holding', 'thank_you', 'junk_decision'
     ) THEN
    reply_type := public.cx_classify_greenlit_reply(p_conversation);
  END IF;
  IF reply_type IS NULL THEN
    RETURN NULL;
  END IF;
  IF NOT public.cx_greenlit_type_enabled(reply_type) THEN
    RETURN 'greenlit_off:' || reply_type;
  END IF;

  text_problem := public.cx_greenlit_text_problem(reply_type, p_body);
  state := public.cx_greenlit_order_state(p_conversation, stored_facts);

  IF reply_type = 'tracking_update' THEN
    IF text_problem IS NOT NULL THEN
      RETURN text_problem;
    END IF;
    IF coalesce(state->>'found', 'false') <> 'true' THEN
      RETURN 'tracking_lookup_missing';
    END IF;
    IF coalesce(state->>'exception', 'false') = 'true' THEN
      RETURN 'tracking_exception_status';
    END IF;
    RETURN NULL;
  ELSIF reply_type = 'address_confirmation' THEN
    IF text_problem IS NOT NULL
       AND NOT public.cx_greenlit_address_change_recorded(p_conversation, stored_facts) THEN
      RETURN 'address_change_unrecorded';
    END IF;
    IF coalesce(state->>'found', 'false') <> 'true' THEN
      RETURN 'address_lookup_missing';
    END IF;
    IF coalesce(state->>'unshipped', 'false') <> 'true' THEN
      RETURN 'address_already_shipped';
    END IF;
    IF coalesce(stored_facts->>'address_matches', '') IN ('false', 'f', 'no') THEN
      RETURN 'address_mismatch';
    END IF;
    IF coalesce(stored_facts->>'address_matches', '') NOT IN ('true', 't', 'yes') THEN
      RETURN 'address_lookup_missing';
    END IF;
    RETURN NULL;
  ELSIF reply_type = 'wholesale_holding' THEN
    RETURN text_problem;
  ELSIF reply_type = 'thank_you' THEN
    IF public.cx_greenlit_creator_or_sample(p_conversation) THEN
      RETURN 'thank_you_creator_or_sample';
    END IF;
    RETURN text_problem;
  ELSIF reply_type = 'junk_decision' THEN
    RETURN 'junk_no_draft';
  END IF;
  RETURN NULL;
END
$fn$;

COMMENT ON FUNCTION public.cx_greenlit_prequeue_block(uuid, text, boolean) IS
  'Hold code that stops auto-queue for a greenlit type, or null. Existing drafts saved before auto_send_greenlit_from are skipped unless p_force is true. Does not write and does not queue.';

CREATE OR REPLACE FUNCTION public.cx_hold_greenlit_draft(p_conversation uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  draft_id uuid;
  draft_body text;
BEGIN
  IF p_conversation IS NULL OR coalesce(p_reason, '') = '' THEN
    RETURN;
  END IF;
  SELECT d.id, d.body INTO draft_id, draft_body
    FROM public.suggested_drafts d
   WHERE d.conversation_id = p_conversation
     AND NOT d.superseded
   ORDER BY d.drafted_at DESC
   LIMIT 1;
  IF draft_id IS NULL OR position('[Cannot auto-send:' IN coalesce(draft_body, '')) > 0 THEN
    RETURN;
  END IF;
  UPDATE public.suggested_drafts
     SET body = '[Cannot auto-send: ' || p_reason || ']' || E'\n\n' || body
   WHERE id = draft_id;
END
$fn$;

REVOKE ALL ON FUNCTION public.cx_hold_greenlit_draft(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cx_hold_greenlit_draft(uuid, text) TO service_role;

-- Same decision as the live preview, plus the reply-window hold and the greenlit check.
CREATE OR REPLACE FUNCTION public.cx_auto_send_preview(p_conversation uuid, p_body text, p_notes integer DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO ''
AS $fn$
DECLARE
  c record;
  last_in text;
  last_in_at timestamptz;
  already text;
  q_latest record;
  has_q boolean;
  notes int;
  missing text[];
  partial boolean;
  attachment boolean;
  amazon_problem text;
  review_problem text;
  greenlit_block text;
BEGIN
  IF coalesce((SELECT value FROM public.cx_settings WHERE key = 'auto_send_ready'), 'false'::jsonb) <> 'true'::jsonb THEN
    RETURN 'disabled';
  END IF;

  SELECT conv.id, conv.origin, conv.shop, conv.status, conv.flag, conv.topic, conv.subject,
         conv.order_number, conv.kind, conv.customer_handle, conv.external_id, st.bucket
    INTO c
    FROM public.conversations conv
    JOIN public.cx_conversation_state st ON st.conversation_id = conv.id
   WHERE conv.id = p_conversation;
  IF NOT FOUND THEN
    RETURN 'not_found';
  ELSIF c.bucket IS DISTINCT FROM 'inbox' THEN
    RETURN 'not_inbox';
  ELSIF c.status::text = 'ignored' THEN
    RETURN 'junk_ignored';
  ELSIF public.cx_meta_comment_should_ignore(c.origin, c.external_id, c.id) THEN
    RETURN 'meta_comment_no_reply';
  ELSIF c.flag IS NOT NULL
     AND c.flag !~* '^Not sending: a teammate or chatbot already replied' THEN
    RETURN 'flagged';
  ELSIF coalesce(c.order_number, '') LIKE 'EGGSYTEST-%' THEN
    RETURN 'test_ticket';
  ELSIF coalesce(c.topic, '') ~* '(affiliate|spam|newsletter|sourcing)' THEN
    RETURN 'junk_topic';
  ELSIF EXISTS (
    SELECT 1 FROM public.reply_queue q
     WHERE q.conversation_id = p_conversation
       AND q.status IN ('queued', 'sending')
  ) THEN
    RETURN 'already_queued';
  END IF;

  notes := p_notes;
  IF notes IS NULL THEN
    notes := coalesce((SELECT count(*)::int FROM regexp_matches(coalesce(p_body, ''), '\[[^\]]*\]', 'g')), 0);
  END IF;
  missing := public.cx_draft_missing_actions(p_conversation, p_body);
  partial := EXISTS (
    SELECT 1 FROM public.messages s
    WHERE s.conversation_id = p_conversation
      AND s.direction::text IN ('inbound', 'outbound')
      AND s.body LIKE '[Summary by Eggsy%'
      AND NOT EXISTS (
        SELECT 1 FROM public.messages v
        WHERE v.conversation_id = s.conversation_id
          AND v.direction = s.direction
          AND v.body NOT LIKE '[Summary by Eggsy%'
          AND abs(extract(epoch FROM v.sent_at - s.sent_at)) < 7200
      )
  );
  attachment := EXISTS (
    SELECT 1 FROM public.messages x
    WHERE x.conversation_id = p_conversation AND x.attachment_missing
  );
  IF notes > 0 OR coalesce(cardinality(missing), 0) > 0 OR partial OR attachment OR coalesce(btrim(p_body), '') = '' THEN
    RETURN 'not_ready';
  END IF;

  SELECT m.body, m.sent_at INTO last_in, last_in_at
    FROM public.messages m
   WHERE m.conversation_id = p_conversation
     AND m.direction = 'inbound'
   ORDER BY m.sent_at DESC
   LIMIT 1;

  IF last_in_at IS NOT NULL THEN
    SELECT left(m.author || ': ' || m.body, 160) INTO already
      FROM public.messages m
     WHERE m.conversation_id = p_conversation
       AND m.sent_at >= last_in_at
       AND (
         (m.direction = 'outbound' AND NOT public.cx_is_internal_outbound(m.author, m.body))
         OR (
           m.direction = 'note'
           AND (
             m.author ~* 'chatbot auto-reply'
             OR m.author ~* 'customer service[0-9]'
             OR (
               m.author ~* 'lucky egg'
               AND m.author !~* 'automatic notice'
               AND m.body !~* '(eggsy log:|imported from|started the chat|chat ended|has been assigned|chat was assigned|timed out|order delivered|signed for|we''ve shipped)'
             )
           )
         )
       )
     ORDER BY m.sent_at
     LIMIT 1;
  END IF;

  SELECT q.status, q.cancelled_by, q.body, q.send_error
    INTO q_latest
    FROM public.reply_queue q
   WHERE q.conversation_id = p_conversation
   ORDER BY q.queued_at DESC NULLS LAST
   LIMIT 1;
  has_q := FOUND;

  IF already IS NOT NULL THEN
    RETURN 'already_replied';
  ELSIF has_q AND q_latest.status = 'cancelled' AND (
         coalesce(q_latest.cancelled_by, '') ~* '(already replied|team already|teammate|chatbot already)'
         OR q_latest.body IS NOT DISTINCT FROM p_body
       ) THEN
    RETURN CASE
      WHEN coalesce(q_latest.cancelled_by, '') ~* '(already replied|team already|teammate|chatbot already)'
        THEN 'cancelled_already_replied'
      ELSE 'cancelled_same_draft'
    END;
  ELSIF has_q AND q_latest.status = 'failed' AND q_latest.body IS NOT DISTINCT FROM p_body THEN
    RETURN 'previous_send_failed';
  ELSIF public.cx_is_us_eu_ticket(c.origin, c.shop)
     AND (
       public.cx_is_refund_ticket(c.topic, c.subject, p_body, last_in)
       OR EXISTS (
         SELECT 1 FROM public.cx_actions a
          WHERE a.conversation_id = p_conversation AND a.type = 'refund'
       )
     ) THEN
    RETURN 'us_eu_refund_escalate';
  END IF;

  IF c.origin::text LIKE 'amazon%' THEN
    amazon_problem := public.cx_amazon_reply_problem(p_body);
  END IF;
  IF amazon_problem IS NOT NULL THEN
    RETURN 'amazon_not_plain:' || amazon_problem;
  ELSIF c.origin::text = 'wix_mmc_form'
     AND NOT EXISTS (
       SELECT 1 FROM public.email_send_channels e
        WHERE e.origin = c.origin AND e.enabled
     ) THEN
    RETURN 'no_send_path';
  END IF;

  IF coalesce(c.kind, 'message') = 'review' OR c.origin::text = 'judgeme' THEN
    review_problem := public.cx_review_reply_problem(p_body);
    IF review_problem IS NOT NULL THEN
      RETURN 'guard_blocked:' || review_problem;
    END IF;
    IF c.origin::text LIKE 'amazon%' THEN
      IF p_body ~* 'https?://|www\.' THEN
        RETURN 'guard_blocked:Amazon review replies must be plain text with no links.';
      ELSIF p_body ~* '(discount|promo|voucher|coupon)\s*code|\mnewsletter\M|\mfollow\s+us\M|\m\d{1,2}\s?%\s*off\M' THEN
        RETURN 'guard_blocked:Amazon review replies cannot include marketing';
      END IF;
    END IF;
  END IF;

  IF public.cx_has_placeholder(p_body) THEN
    RETURN 'not_ready';
  END IF;

  greenlit_block := public.cx_greenlit_prequeue_block(p_conversation, p_body, false);
  IF greenlit_block IS NOT NULL THEN
    RETURN greenlit_block;
  END IF;
  IF public.cx_reply_window_block(p_conversation) IS NOT NULL THEN
    RETURN 'reply_window_expired';
  END IF;
  RETURN 'queued';
END
$fn$;

-- Live auto-queue, with the greenlit check immediately before a row is inserted.
-- A block adds a bracket on that new draft so it stays in Gaps. It does not run
-- for drafts saved before auto_send_greenlit_from.
CREATE OR REPLACE FUNCTION public.cx_queue_ready_draft(p_conversation uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c record;
  r record;
  last_in text;
  last_in_at timestamptz;
  already text;
  amazon_problem text;
  q_latest record;
  hold text;
  result text;
  greenlit_block text;
  depth int := coalesce(nullif(current_setting('eggsy.queue_ready_depth', true), ''), '0')::int;
begin
  if depth > 0 then
    return 'in_progress';
  end if;
  perform set_config('eggsy.queue_ready_depth', '1', true);

  begin
    if coalesce((select value from public.cx_settings where key = 'auto_send_ready'), 'false'::jsonb) <> 'true'::jsonb then
      result := 'disabled';
    else
      select conv.id, conv.origin, conv.shop, conv.status, conv.flag, conv.topic, conv.subject,
             conv.order_number, conv.kind, conv.customer_handle, conv.external_id, st.bucket,
             st.last_customer_at, st.last_reply_at
        into c
        from public.conversations conv
        join public.cx_conversation_state st on st.conversation_id = conv.id
       where conv.id = p_conversation;
      if not found then
        result := 'not_found';
      elsif c.bucket is distinct from 'inbox' then
        result := 'not_inbox';
      elsif c.status = 'ignored' then
        result := 'junk_ignored';
      elsif public.cx_meta_comment_should_ignore(c.origin, c.external_id, c.id) then
        result := 'meta_comment_no_reply';
      elsif c.flag is not null
         and c.flag !~* '^Not sending: a teammate or chatbot already replied' then
        result := 'flagged';
      elsif coalesce(c.order_number, '') like 'EGGSYTEST-%' then
        result := 'test_ticket';
      elsif coalesce(c.topic, '') ~* '(affiliate|spam|newsletter|sourcing)' then
        result := 'junk_topic';
      elsif exists (
        select 1 from public.reply_queue q
         where q.conversation_id = p_conversation
           and q.status in ('queued', 'sending')
      ) then
        result := 'already_queued';
      else
        select x.conversation_id, x.notes, x.missing_actions, x.partial_history,
               x.attachment_missing, x.drafted_at, d0.body, d0.id as draft_id
          into r
          from public.cx_draft_readiness() x
          join public.suggested_drafts d0
            on d0.conversation_id = x.conversation_id and not d0.superseded
         where x.conversation_id = p_conversation
         order by d0.drafted_at desc
         limit 1;
        if not found or r.notes > 0 or cardinality(r.missing_actions) > 0
           or r.partial_history or r.attachment_missing or coalesce(btrim(r.body), '') = '' then
          result := 'not_ready';
        else
          select m.body, m.sent_at into last_in, last_in_at
            from public.messages m
           where m.conversation_id = p_conversation
             and m.direction = 'inbound'
           order by m.sent_at desc
           limit 1;

          if last_in_at is not null then
            select left(m.author || ': ' || m.body, 160) into already
              from public.messages m
             where m.conversation_id = p_conversation
               and m.sent_at >= last_in_at
               and (
                 (m.direction = 'outbound' and not public.cx_is_internal_outbound(m.author, m.body))
                 or (
                   m.direction = 'note'
                   and (
                     m.author ~* 'chatbot auto-reply'
                     or m.author ~* 'customer service[0-9]'
                     or (
                       m.author ~* 'lucky egg'
                       and m.author !~* 'automatic notice'
                       and m.body !~* '(eggsy log:|imported from|started the chat|chat ended|has been assigned|chat was assigned|timed out|order delivered|signed for|we''ve shipped)'
                     )
                   )
                 )
               )
             order by m.sent_at
             limit 1;
          end if;

          select q.status, q.cancelled_by, q.body, q.send_error
            into q_latest
            from public.reply_queue q
           where q.conversation_id = p_conversation
           order by q.queued_at desc nulls last
           limit 1;

          if already is not null then
            hold := 'already_replied';
            perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
            result := hold;
          elsif found
             and q_latest.status = 'cancelled'
             and (
               coalesce(q_latest.cancelled_by, '') ~* '(already replied|team already|teammate|chatbot already)'
               or q_latest.body is not distinct from r.body
             ) then
            hold := case
              when coalesce(q_latest.cancelled_by, '') ~* '(already replied|team already|teammate|chatbot already)'
                then 'cancelled_already_replied'
              else 'cancelled_same_draft'
            end;
            perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
            result := hold;
          elsif found and q_latest.status = 'failed' and q_latest.body is not distinct from r.body then
            result := 'previous_send_failed';
          elsif public.cx_is_us_eu_ticket(c.origin, c.shop)
             and (
               public.cx_is_refund_ticket(c.topic, c.subject, r.body, last_in)
               or exists (
                 select 1 from public.cx_actions a
                  where a.conversation_id = p_conversation and a.type = 'refund'
               )
             ) then
            hold := 'us_eu_refund_escalate';
            perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
            result := hold;
          else
            if c.origin::text like 'amazon%' then
              amazon_problem := public.cx_amazon_reply_problem(r.body);
            end if;
            if amazon_problem is not null then
              hold := 'amazon_not_plain:' || amazon_problem;
              perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
              result := hold;
            elsif c.origin = 'wix_mmc_form'
               and not exists (
                 select 1 from public.email_send_channels e
                  where e.origin = c.origin and e.enabled
               ) then
              hold := 'no_send_path';
              perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
              result := hold;
            else
              begin
                greenlit_block := public.cx_greenlit_prequeue_block(p_conversation, r.body, false);
                if greenlit_block is not null then
                  perform public.cx_hold_greenlit_draft(p_conversation, greenlit_block);
                  result := greenlit_block;
                elsif public.cx_reply_window_block(p_conversation) is not null then
                  result := 'reply_window_expired';
                else
                  insert into public.reply_queue (conversation_id, body, queued_by, requires_action, auto_sent)
                  values (p_conversation, r.body, 'eggsy-auto', false, true);
                  result := 'queued';
                end if;
              exception when others then
                hold := 'guard_blocked:' || sqlerrm;
                perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
                result := hold;
              end;
            end if;
          end if;
        end if;
      end if;
    end if;
  exception when others then
    perform set_config('eggsy.queue_ready_depth', '0', true);
    raise;
  end;

  perform set_config('eggsy.queue_ready_depth', '0', true);
  return result;
end
$function$;

-- Backup for any other auto-sent insert. Staff sends (auto_sent false) are not checked here.
CREATE OR REPLACE FUNCTION public.cx_reply_queue_greenlit_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  block text;
BEGIN
  IF coalesce(NEW.auto_sent, false) THEN
    block := public.cx_greenlit_prequeue_block(NEW.conversation_id, NEW.body, false);
    IF block IS NOT NULL THEN
      RAISE EXCEPTION '%', block USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS reply_queue_greenlit_guard ON public.reply_queue;
CREATE TRIGGER reply_queue_greenlit_guard
  BEFORE INSERT ON public.reply_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.cx_reply_queue_greenlit_guard();

DROP FUNCTION IF EXISTS public.cx_save_draft(uuid, text, text[], jsonb, text, text, text, text);

CREATE OR REPLACE FUNCTION public.cx_save_draft(
  p_conversation_id uuid,
  p_body text,
  p_blocking_notes text[] DEFAULT '{}'::text[],
  p_follow_up_actions jsonb DEFAULT '[]'::jsonb,
  p_context text DEFAULT NULL,
  p_language text DEFAULT NULL,
  p_body_en text DEFAULT NULL,
  p_author text DEFAULT 'Eggsy',
  p_reply_type text DEFAULT NULL,
  p_reply_facts jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  jwt_role text := coalesce(current_setting('request.jwt.claim.role', true), '');
  note text;
  body text;
  ctx text;
  lang text;
  draft_id uuid;
  act jsonb;
  desc_text text;
  team text;
  facts jsonb := CASE WHEN jsonb_typeof(p_reply_facts) = 'object' THEN p_reply_facts ELSE NULL END;
  allowed text[] := ARRAY['marketing','warehouse','product','cx','directors','ops','sales','finance'];
  ben_email text := 'ben.p@luckyegg.co';
  ben_name text := 'Ben Pullen';
  reply_type text := nullif(btrim(coalesce(p_reply_type, '')), '');
BEGIN
  IF jwt_role = 'anon' OR (jwt_role = 'authenticated' AND NOT public.is_lucky_egg_staff()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_conversation_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = p_conversation_id) THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;
  IF reply_type IS NOT NULL AND reply_type NOT IN (
       'tracking_update', 'address_confirmation', 'wholesale_holding', 'thank_you', 'junk_decision'
     ) THEN
    RAISE EXCEPTION 'reply_type must be a greenlit type or null';
  END IF;
  body := btrim(coalesce(p_body, ''));
  IF body = '' THEN
    RAISE EXCEPTION 'draft body is empty';
  END IF;
  lang := nullif(lower(btrim(coalesce(p_language, ''))), '');
  IF lang IS NOT NULL AND lang !~ '^[a-z]{2}$' THEN
    RAISE EXCEPTION 'language must be an ISO 639-1 code';
  END IF;
  ctx := nullif(btrim(coalesce(p_context, '')), '');

  IF p_blocking_notes IS NOT NULL THEN
    FOREACH note IN ARRAY p_blocking_notes LOOP
      note := btrim(note);
      IF note IS NULL OR note = '' THEN
        CONTINUE;
      END IF;
      IF note ~ '[\[\]]' THEN
        RAISE EXCEPTION 'blocking notes cannot contain square brackets';
      END IF;
      IF position('[' || note || ']' IN body) = 0 THEN
        body := '[' || note || ']' || E'\n\n' || body;
      END IF;
    END LOOP;
  END IF;

  IF jsonb_typeof(coalesce(p_follow_up_actions, '[]'::jsonb)) = 'array' THEN
    FOR act IN SELECT value FROM jsonb_array_elements(p_follow_up_actions) LOOP
      IF coalesce(act->>'kind', '') IN ('order_lookup', 'address_check') THEN
        facts := coalesce(facts, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
          'order_found', act->>'order_found',
          'shipping_status', act->>'shipping_status',
          'exception', act->>'exception',
          'shipped', act->>'shipped',
          'address_matches', act->>'address_matches',
          'address_changed', act->>'address_changed',
          'source', coalesce(act->>'source', act->>'kind'),
          'order_ref', act->>'order_ref'
        ));
      END IF;
    END LOOP;
  END IF;

  UPDATE public.suggested_drafts
     SET superseded = true, superseded_at = now()
   WHERE conversation_id = p_conversation_id AND NOT superseded;

  INSERT INTO public.suggested_drafts (
    conversation_id, body, body_en, language, author, context, reply_type, reply_facts
  ) VALUES (
    p_conversation_id,
    body,
    nullif(btrim(coalesce(p_body_en, '')), ''),
    lang,
    coalesce(nullif(btrim(p_author), ''), 'Eggsy'),
    ctx,
    reply_type,
    facts
  )
  RETURNING id INTO draft_id;

  IF jsonb_typeof(coalesce(p_follow_up_actions, '[]'::jsonb)) = 'array' THEN
    FOR act IN SELECT value FROM jsonb_array_elements(p_follow_up_actions) LOOP
      IF coalesce(act->>'kind', '') IN ('order_lookup', 'address_check') THEN
        CONTINUE;
      END IF;
      desc_text := btrim(coalesce(act->>'description', act->>'note', ''));
      IF desc_text = '' THEN
        CONTINUE;
      END IF;
      team := lower(btrim(coalesce(act->>'owner_team', act->>'owner', act->>'team', 'cx')));
      IF team IS NULL OR NOT (team = ANY (allowed)) THEN
        team := 'cx';
      END IF;
      IF EXISTS (
        SELECT 1 FROM public.cx_actions a
         WHERE a.conversation_id = p_conversation_id
           AND a.type = 'follow_up'
           AND a.status IN ('pending', 'created')
           AND a.details->>'description' = desc_text
      ) THEN
        CONTINUE;
      END IF;
      INSERT INTO public.cx_actions (conversation_id, type, status, details, created_by)
      VALUES (
        p_conversation_id,
        'follow_up',
        'pending',
        jsonb_strip_nulls(jsonb_build_object(
          'description', desc_text,
          'owner_team', team,
          'source', 'auto:draft-follow-up',
          'draft_id', draft_id,
          'to', nullif(act->>'to', ''),
          'to_name', nullif(act->>'to_name', ''),
          'kind', nullif(act->>'kind', '')
        )),
        'Eggsy (draft follow-up)'
      );
    END LOOP;
  END IF;

  IF reply_type = 'wholesale_holding' AND to_regclass('public.cx_colleagues') IS NOT NULL THEN
    SELECT c.email, c.display_name INTO ben_email, ben_name
      FROM public.cx_colleagues c
     WHERE c.active
       AND (c.display_name = 'Ben Pullen' OR c.email = 'ben.p@luckyegg.co')
     ORDER BY (c.display_name = 'Ben Pullen') DESC
     LIMIT 1;
    ben_email := coalesce(ben_email, 'ben.p@luckyegg.co');
    ben_name := coalesce(ben_name, 'Ben Pullen');
    IF NOT EXISTS (
      SELECT 1 FROM public.cx_actions a
       WHERE a.conversation_id = p_conversation_id
         AND a.type = 'follow_up'
         AND a.status IN ('pending', 'created')
         AND (
           a.details->>'to' = ben_email
           OR coalesce(a.details->>'description', '') ILIKE '%Ben Pullen%'
         )
    ) THEN
      INSERT INTO public.cx_actions (conversation_id, type, status, details, created_by)
      VALUES (
        p_conversation_id,
        'follow_up',
        'pending',
        jsonb_build_object(
          'description', 'Forward this wholesale enquiry to Ben Pullen (sales)',
          'owner_team', 'sales',
          'source', 'auto:draft-follow-up',
          'draft_id', draft_id,
          'to', ben_email,
          'to_name', ben_name,
          'kind', 'colleague'
        ),
        'Eggsy (draft follow-up)'
      );
    END IF;
  END IF;

  RETURN draft_id;
END
$fn$;

COMMENT ON FUNCTION public.cx_save_draft(uuid, text, text[], jsonb, text, text, text, text, text, jsonb) IS
  'Save a draft. Brackets are only for p_blocking_notes. Follow-ups become pending cx_actions and do not block auto-send. p_reply_type and p_reply_facts record a greenlit type and the lookup. A wholesale holding reply also logs a follow-up to Ben Pullen. The colleague auto-forward mailer is not called, because that mailer resolves the ticket.';

REVOKE ALL ON FUNCTION public.cx_save_draft(uuid, text, text[], jsonb, text, text, text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cx_save_draft(uuid, text, text[], jsonb, text, text, text, text, text, jsonb) TO authenticated, service_role;

-- Read-only. Does not update a draft and does not queue a reply.
-- would_ready is the hypothetical: instruction-only brackets removed, then every
-- current guard plus the new check. A fill-in bracket still counts as a gap.
CREATE OR REPLACE FUNCTION public.cx_greenlit_dry_run()
RETURNS TABLE(
  conversation_id uuid,
  author text,
  reply_type text,
  gapped boolean,
  safety_block text,
  existing_hold text,
  would_ready boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  rec record;
  work text;
  note text;
  gapped_row boolean;
  removable boolean;
  safety text;
  hold text;
  send_body text;
BEGIN
  FOR rec IN
    SELECT DISTINCT ON (d.conversation_id)
           d.conversation_id, d.author, d.body
      FROM public.suggested_drafts d
      JOIN public.cx_conversation_state st ON st.conversation_id = d.conversation_id
     WHERE NOT d.superseded
       AND st.bucket = 'inbox'
     ORDER BY d.conversation_id, d.drafted_at DESC
  LOOP
    work := coalesce(rec.body, '');
    gapped_row := false;
    IF work ~ '\[[^\]]*\]' THEN
      FOR note IN
        SELECT m[1] FROM regexp_matches(work, '\[([^\]]*)\]', 'g') AS m
      LOOP
        removable := note ~* '(is this spam|possibly spam|forward to sales|forward to ben|pass (it |this )?to sales)'
          OR (
            length(note) >= 80
            AND note ~* '(check |look up|lookup|hatty to decide|delete this note)'
            AND note !~* '(replace|add the|fill in|rewrite|instead of|tracking number|where the parcel|delivery date)'
          );
        IF NOT removable THEN
          gapped_row := true;
        ELSE
          work := replace(work, '[' || note || ']', '');
        END IF;
      END LOOP;
      work := btrim(regexp_replace(regexp_replace(work, E'[ \t]+\n', E'\n', 'g'), E'\n{3,}', E'\n\n', 'g'));
    END IF;
    send_body := work;
    reply_type := public.cx_classify_greenlit_reply(rec.conversation_id);
    IF reply_type IS NULL THEN
      safety := NULL;
    ELSE
      safety := public.cx_greenlit_prequeue_block(
        rec.conversation_id,
        public.cx_greenlit_customer_text(rec.body),
        true
      );
    END IF;
    hold := public.cx_auto_send_preview(rec.conversation_id, send_body, NULL);
    conversation_id := rec.conversation_id;
    author := rec.author;
    gapped := gapped_row OR send_body ~ '\[[^\]]*\]';
    safety_block := safety;
    existing_hold := hold;
    would_ready := reply_type IS NOT NULL
      AND NOT gapped
      AND safety IS NULL
      AND hold = 'queued';
    RETURN NEXT;
  END LOOP;
END
$fn$;

COMMENT ON FUNCTION public.cx_greenlit_dry_run() IS
  'Read-only classification of current Inbox drafts against the greenlit rules. Does not update drafts and does not queue replies.';

REVOKE ALL ON FUNCTION public.cx_greenlit_dry_run() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cx_greenlit_dry_run() TO authenticated, service_role;

INSERT INTO public.kb_articles (
  slug, title, category, body, applies_to, language,
  source_name, source_updated_at, status, notes, updated_by, published_at
) VALUES (
  'greenlit-auto-send',
  'Greenlit auto-send replies',
  'Tone & templates',
  $kb$## Who this is for (Hatty, 23 Nov 2026)

The Eggsy drafter and the batch drafter (the draft author Claude) both use this article. It is returned by `kb_for_origin` for every channel. Save the draft with `public.cx_save_draft`. Pass the type as `p_reply_type` and the lookup as `p_reply_facts`. Do not put the lookup, a spam decision, or a forward in square brackets.

Square brackets stay only for a real gap. These five types are switched on in `cx_settings` key `auto_send_greenlit_types`. A type set to false goes to Gaps.

These types do not change replacement follow-ups, gameplay questions, missing parts, cancellations, UK damaged items, or refunds. If the message is one of those, draft it the way you already do.

These guards stay as they are: US and EU refunds and replacements are never auto-approved; Amazon replies are plain text only, with no links, marketing, review requests or emoji; delivered-not-arrived still asks them to check with neighbours first and is handled by a person; a reply that promises an action still needs the action row; the already-answered-on-platform check still applies; never say the artwork is not AI. Comments still get no reply unless they @mention us and ask a question.

## 1. Where's my order / tracking update

All channels. Look the order up yourself before you draft.

- Website orders: call the existing cx-actions action `lookup_order`. That is a read-only Shopify Admin query. Do not create an order, a draft order, or a refund.
- Amazon, TikTok and Walmart: read `public.cx_draft_order_lookup(conversation_id)`, which is the marketplace order already stored. It has status, tracking, city and postcode only.

Record it on the draft:

```sql
p_reply_type := 'tracking_update'
p_reply_facts := '{"order_found":true,"shipping_status":"in_transit","exception":false,"source":"shopify","order_ref":"13513"}'
```

If the lookup fails or no order is found, pass a blocking note and stop. The draft stays in Gaps.

Only a status update may go out: where it is, the carrier, and the tracking number when you have one. If it has not shipped, say so. "We usually pick and ship orders within 72 hours" is allowed. Do not mention a refund, replacement, compensation, or a delivery date.

If tracking shows delivered, lost, failed, returned, or an exception, do not use this type. Leave a blocking note. A person handles it, including the neighbours-first steps when it shows delivered but the customer says it has not arrived.

## 2. Address confirmation before dispatch

Use this only when the order exists and has not shipped, and you have compared the address the customer sent with the address on the order. Record:

```sql
p_reply_type := 'address_confirmation'
p_reply_facts := '{"order_found":true,"shipped":false,"address_matches":true,"address_changed":false,"source":"shopify"}'
```

If it has shipped, or the addresses do not match, or you cannot find the order, use a blocking note. Never say the address was changed or updated unless a change actually happened and you record `"address_changed":true` (or a follow-up action that says the address was changed).

## 3. Wholesale / B2B holding reply

Run the junk check first. Junk is ignored with no draft. A genuine wholesale enquiry gets this holding reply and nothing more. For an EU customer, translate only this sentence. Do not add prices, a currency symbol, a minimum, MOQ, a discount, terms, exclusivity, or permission to resell.

> Hi there, thanks for getting in touch about stocking our games. Our sales team will be in touch.

Save it as `p_reply_type := 'wholesale_holding'` with no blocking notes. `cx_save_draft` logs a pending follow-up to forward the enquiry to Ben Pullen (sales), using the same to / to_name / kind fields as a colleague forward. It does not send that email itself. The automatic colleague forward is only for mail addressed to a colleague, and that path resolves the ticket.

## 4. Thank-you, praise, or a closing message

A short friendly reply. No promise, no "we'll pass this on", no refund, replacement, or discount.

> Hi {first name}! Thanks so much, that really means a lot to us.

Do not use this for a creator, influencer, UGC or ad-code message, or a free-sample recipient. Those go to a person. A product fault or a question is not a thank-you.

`p_reply_type := 'thank_you'`

## 5. Junk or a genuine customer

Decide it yourself. Never write a note such as "is this spam?".

Junk is what the import filters already drop: sales pitches, phishing, platform notifications, and tickets whose topic is affiliate, spam, newsletter, or sourcing. Ignore junk. Do not save a draft.

A genuine customer gets a normal draft for whatever they asked. That draft is not this type unless it is one of the four replies above.
$kb$,
  NULL,
  'en',
  'Hatty Innes, 23 Nov 2026',
  '2026-11-23',
  'published',
  'Both drafters read this via kb_for_origin. Pre-queue check: cx_greenlit_prequeue_block. Toggle types in cx_settings.auto_send_greenlit_types.',
  'Eggsy',
  now()
)
ON CONFLICT (slug) DO UPDATE
  SET title = excluded.title,
      category = excluded.category,
      body = excluded.body,
      applies_to = excluded.applies_to,
      source_name = excluded.source_name,
      source_updated_at = excluded.source_updated_at,
      status = excluded.status,
      notes = excluded.notes,
      updated_by = excluded.updated_by,
      published_at = coalesce(public.kb_articles.published_at, now()),
      updated_at = now();

UPDATE public.kb_articles
   SET body = body || $extra$

## Greenlit auto-send (Hatty, 23 Nov 2026)
Five reply types can go out without a bracket note when the drafter has done the lookup and recorded it on the draft: a tracking status update, an address confirmation before dispatch, a wholesale holding reply, a short thank-you, and the junk-or-genuine decision. The rules, the fixed wholesale sentence, and what still goes to Gaps are in "Greenlit auto-send replies". Do not use a bracket note for "check tracking", "is this spam?", or "forward to sales". Other reply types are unchanged.
$extra$,
       updated_at = now(),
       updated_by = 'Eggsy',
       source_updated_at = '2026-11-23'
 WHERE slug = 'how-we-write-replies'
   AND body NOT LIKE '%Greenlit auto-send (Hatty, 23 Nov 2026)%';

DO $check$
BEGIN
  IF public.cx_greenlit_text_problem('tracking_update', 'Your refund is on its way') IS DISTINCT FROM 'tracking_remedy' THEN
    RAISE EXCEPTION 'tracking refund should block';
  END IF;
  IF public.cx_greenlit_text_problem('tracking_update', 'A replacement is on its way') IS DISTINCT FROM 'tracking_remedy' THEN
    RAISE EXCEPTION 'tracking replacement should block';
  END IF;
  IF public.cx_greenlit_text_problem('tracking_update', 'It should reach you by 24 November') IS DISTINCT FROM 'tracking_delivery_date' THEN
    RAISE EXCEPTION 'delivery date should block';
  END IF;
  IF public.cx_greenlit_text_problem('tracking_update', 'We usually pick and ship orders within 72 hours.') IS NOT NULL THEN
    RAISE EXCEPTION '72 hour dispatch wording should pass';
  END IF;
  IF public.cx_greenlit_text_problem('tracking_update', 'Your order is in transit with Royal Mail. The tracking number is AB12CD.') IS NOT NULL THEN
    RAISE EXCEPTION 'plain tracking status should pass';
  END IF;
  IF public.cx_greenlit_text_problem('address_confirmation', 'We have updated your address.') IS DISTINCT FROM 'address_change_unrecorded' THEN
    RAISE EXCEPTION 'address updated should block';
  END IF;
  IF public.cx_greenlit_text_problem('address_confirmation', 'The address on the order matches the one you sent, and it has not shipped yet.') IS NOT NULL THEN
    RAISE EXCEPTION 'plain address confirmation should pass';
  END IF;
  IF public.cx_greenlit_text_problem('wholesale_holding', 'Hi there, thanks for getting in touch about stocking our games. Our sales team will be in touch.') IS NOT NULL THEN
    RAISE EXCEPTION 'fixed wholesale sentence should pass';
  END IF;
  IF public.cx_greenlit_text_problem('wholesale_holding', 'The minimum order is 6 and the price is £12.') IS DISTINCT FROM 'wholesale_commercial_terms' THEN
    RAISE EXCEPTION 'wholesale price and minimum should block';
  END IF;
  IF public.cx_greenlit_text_problem('wholesale_holding', 'We can offer a discount.') IS DISTINCT FROM 'wholesale_commercial_terms' THEN
    RAISE EXCEPTION 'wholesale discount should block';
  END IF;
  IF public.cx_greenlit_text_problem('thank_you', 'Hi Sam! Thanks so much, that really means a lot to us.') IS NOT NULL THEN
    RAISE EXCEPTION 'plain thank-you should pass';
  END IF;
  IF public.cx_greenlit_text_problem('thank_you', 'We''ve passed this on to the team.') IS DISTINCT FROM 'thank_you_promise' THEN
    RAISE EXCEPTION 'thank-you promise should block';
  END IF;
  IF public.cx_shipping_is_exception('Delivered') IS NOT TRUE THEN
    RAISE EXCEPTION 'delivered is an exception status';
  END IF;
  IF public.cx_shipping_is_exception('in transit') IS NOT FALSE THEN
    RAISE EXCEPTION 'in transit is not an exception';
  END IF;
  IF public.cx_shipping_is_exception('not delivered') IS NOT FALSE THEN
    RAISE EXCEPTION 'not delivered is not an exception status';
  END IF;
  IF public.cx_shipping_is_unshipped('unfulfilled') IS NOT TRUE THEN
    RAISE EXCEPTION 'unfulfilled is unshipped';
  END IF;
END
$check$;
