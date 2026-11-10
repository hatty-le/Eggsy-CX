-- Hatty, 10 Nov 2026 16:45 UK: allow replies that promise a refund, replacement
-- or return to go out / sit in Ready, and automatically log a pending cx_actions
-- row so the promise appears on the ticket Actions panel. Do not block the send.
-- Keep placeholder, Amazon plain-text, US/EU refund escalation and duplicate-send checks.

-- 1) Required customer fields for placing a replacement (MCF whole game or
--    3PL Shopify free part order). Used as drafting guidance and to record
--    what is still missing on an auto-logged pending action.
CREATE OR REPLACE FUNCTION public.cx_action_missing_required_details(
  p_type text,
  p_conversation_id uuid,
  p_details jsonb DEFAULT '{}'::jsonb
) RETURNS text[]
LANGUAGE plpgsql
STABLE
SET search_path TO ''
AS $function$
DECLARE
  c record;
  d jsonb := coalesce(p_details, '{}'::jsonb);
  addr jsonb;
  missing text[] := '{}';
  order_id text;
  first_name text;
  last_name text;
  full_name text;
  address1 text;
  city text;
  zip text;
  country text;
  province text;
  cc text;
BEGIN
  SELECT order_number, customer_name
    INTO c
    FROM public.conversations
   WHERE id = p_conversation_id;

  addr := CASE
    WHEN jsonb_typeof(d->'address') = 'object' THEN d->'address'
    ELSE '{}'::jsonb
  END;

  order_id := nullif(btrim(coalesce(
    d->>'original_order_id',
    d->>'source_order',
    d->>'order_number',
    c.order_number,
    ''
  )), '');

  first_name := nullif(btrim(coalesce(addr->>'firstName', addr->>'first_name', d->>'firstName', d->>'first_name', '')), '');
  last_name  := nullif(btrim(coalesce(addr->>'lastName',  addr->>'last_name',  d->>'lastName',  d->>'last_name',  '')), '');
  full_name  := nullif(btrim(coalesce(addr->>'name', d->>'customer_name', c.customer_name, '')), '');
  address1   := nullif(btrim(coalesce(addr->>'address1', addr->>'addressLine1', addr->>'line1', '')), '');
  city       := nullif(btrim(coalesce(addr->>'city', '')), '');
  zip        := nullif(btrim(coalesce(addr->>'zip', addr->>'postalCode', addr->>'postcode', '')), '');
  country    := nullif(btrim(coalesce(addr->>'countryCode', addr->>'country_code', addr->>'country', '')), '');
  province   := nullif(btrim(coalesce(addr->>'province', addr->>'provinceCode', addr->>'stateOrRegion', addr->>'state', '')), '');
  cc := upper(country);
  IF cc IN ('UK', 'UNITED KINGDOM', 'GREAT BRITAIN', 'ENGLAND', 'SCOTLAND', 'WALES') THEN cc := 'GB'; END IF;
  IF cc IN ('USA', 'UNITED STATES', 'UNITED STATES OF AMERICA') THEN cc := 'US'; END IF;
  IF cc IN ('CANADA') THEN cc := 'CA'; END IF;
  IF cc IN ('AUSTRALIA') THEN cc := 'AU'; END IF;

  IF p_type IN ('replacement', 'refund', 'return') AND order_id IS NULL THEN
    missing := array_append(missing, 'original_order_number');
  END IF;

  IF p_type IN ('replacement', 'return') THEN
    IF NOT (
      (first_name IS NOT NULL AND last_name IS NOT NULL)
      OR (full_name IS NOT NULL AND full_name ~ '\S+\s+\S+')
    ) THEN
      missing := array_append(missing, 'full_name');
    END IF;
    IF address1 IS NULL THEN missing := array_append(missing, 'address_line_1'); END IF;
    IF city     IS NULL THEN missing := array_append(missing, 'city'); END IF;
    IF zip      IS NULL THEN missing := array_append(missing, 'postcode'); END IF;
    IF country  IS NULL THEN missing := array_append(missing, 'country'); END IF;
    IF cc IN ('US', 'CA', 'AU') AND province IS NULL THEN
      missing := array_append(missing, 'county_or_state');
    END IF;
  END IF;

  RETURN missing;
END
$function$;

-- Same type detection as cx_promised_action_types, but does not skip replies
-- that also ask the customer for details. Used when logging the action.
CREATE OR REPLACE FUNCTION public.cx_action_types_in_reply(p_body text, p_flag boolean DEFAULT false)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE
  b text := coalesce(p_body, '');
  types text[] := '{}';
BEGIN
  IF b ~* '(replacement|replacements|\breplace\b|\breplaced\b|\breplacing\b|\bresend\b|\bresending\b|\breship\b|a new (copy|game|order|parcel)|ersatzlieferung|\bersatz\b|remplacement|reemplazo)' THEN
    types := array_append(types, 'replacement');
  END IF;
  IF b ~* '(refund|refunded|refunds|refunding|erstattung|erstatten|rückerstattung|remboursement|reembolso)' THEN
    types := array_append(types, 'refund');
  END IF;
  IF b ~* '(return label|return postage|prepaid return|return address|send (the |it |this |your ).{0,40}back|sending .{0,20}back|return the (item|game|parcel|order|package|headset|microphone)|return your (item|game|parcel|order|package)|returning the |\barrange a return\b|\ba return to\b|rücksendung|zurückschicken|\bretoure\b|devoluci[oó]n)' THEN
    types := array_append(types, 'return');
  END IF;
  IF coalesce(p_flag, false) AND types = '{}' THEN
    RETURN ARRAY['any'];
  END IF;
  RETURN types;
END
$function$;

-- Insert a pending cx_actions row for each promised type with no open action.
CREATE OR REPLACE FUNCTION public.cx_log_promised_actions_from_reply(
  p_conversation_id uuid,
  p_body text,
  p_reply_queue_id uuid DEFAULT NULL,
  p_draft_id uuid DEFAULT NULL
) RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  types text[];
  t text;
  missing text[];
  inserted uuid[] := '{}';
  new_id uuid;
  details jsonb;
BEGIN
  IF p_conversation_id IS NULL THEN
    RETURN inserted;
  END IF;
  types := public.cx_action_types_in_reply(p_body, false);
  IF types IS NULL OR cardinality(types) = 0 THEN
    RETURN inserted;
  END IF;

  FOREACH t IN ARRAY types LOOP
    IF t IS NULL OR t = 'any' THEN
      CONTINUE;
    END IF;
    IF t NOT IN ('replacement', 'refund', 'return') THEN
      CONTINUE;
    END IF;
    IF EXISTS (
      SELECT 1
        FROM public.cx_actions a
       WHERE a.conversation_id = p_conversation_id
         AND a.type = t
         AND a.status NOT IN ('done', 'failed', 'cancelled')
    ) THEN
      CONTINUE;
    END IF;

    missing := public.cx_action_missing_required_details(t, p_conversation_id, '{}'::jsonb);
    details := jsonb_build_object(
      'source', 'auto: promised in reply',
      'missing_details', to_jsonb(missing),
      'awaiting_details', coalesce(cardinality(missing), 0) > 0
    );
    IF p_reply_queue_id IS NOT NULL THEN
      details := details || jsonb_build_object('reply_queue_id', p_reply_queue_id);
    END IF;
    IF p_draft_id IS NOT NULL THEN
      details := details || jsonb_build_object('draft_id', p_draft_id);
    END IF;

    INSERT INTO public.cx_actions (
      conversation_id, type, status, details, created_by
    ) VALUES (
      p_conversation_id,
      t,
      'pending',
      details,
      'Eggsy (auto: promised in reply)'
    )
    RETURNING id INTO new_id;

    inserted := array_append(inserted, new_id);
  END LOOP;

  RETURN inserted;
END
$function$;

CREATE OR REPLACE FUNCTION public.cx_log_promised_actions_on_queue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  draft_id uuid;
BEGIN
  IF new.status IS NULL OR new.status NOT IN ('queued', 'sending', 'sent') THEN
    RETURN NULL;
  END IF;
  IF tg_op = 'UPDATE'
     AND new.status IS NOT DISTINCT FROM old.status
     AND new.body IS NOT DISTINCT FROM old.body THEN
    RETURN NULL;
  END IF;

  SELECT d.id
    INTO draft_id
    FROM public.suggested_drafts d
   WHERE d.conversation_id = new.conversation_id
     AND NOT d.superseded
     AND d.body IS NOT DISTINCT FROM new.body
   ORDER BY d.drafted_at DESC
   LIMIT 1;

  IF draft_id IS NULL THEN
    SELECT d.id
      INTO draft_id
      FROM public.suggested_drafts d
     WHERE d.conversation_id = new.conversation_id
       AND NOT d.superseded
     ORDER BY d.drafted_at DESC
     LIMIT 1;
  END IF;

  PERFORM public.cx_log_promised_actions_from_reply(
    new.conversation_id, new.body, new.id, draft_id
  );
  RETURN NULL;
END
$function$;

DROP TRIGGER IF EXISTS cx_log_promised_actions_on_queue ON public.reply_queue;
CREATE TRIGGER cx_log_promised_actions_on_queue
  AFTER INSERT OR UPDATE OF status, body ON public.reply_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.cx_log_promised_actions_on_queue();

-- 2) Relax the send guard: promising a remedy no longer blocks the queue.
CREATE OR REPLACE FUNCTION public.reply_queue_action_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  -- Hatty, 10 Nov 2026 16:45 UK: do not block a send because the reply
  -- promises a refund, replacement or return. The AFTER trigger
  -- cx_log_promised_actions_on_queue logs a pending action instead.
  -- Placeholder, Amazon plain-text, review and meta-comment guards still apply.
  RETURN new;
END
$function$;

-- 3) Relax readiness: promised remedies no longer hold a draft in Gaps.
CREATE OR REPLACE FUNCTION public.cx_draft_readiness()
RETURNS TABLE(conversation_id uuid, notes integer, missing_actions text[], partial_history boolean, attachment_missing boolean, drafted_at timestamp with time zone)
LANGUAGE sql
SET search_path TO ''
AS $function$
  select d.conversation_id,
         coalesce((select count(*)::int from regexp_matches(d.body, '\[[^\]]*\]', 'g')), 0),
         -- Promised refund/replacement/return no longer listed as missing;
         -- those drafts can sit in Ready. Actions are logged when the reply
         -- is queued or sent.
         '{}'::text[],
         exists (select 1 from public.messages s
                 where s.conversation_id = d.conversation_id
                   and s.direction::text in ('inbound', 'outbound')
                   and s.body like '[Summary by Eggsy%'
                   and not exists (select 1 from public.messages v
                                   where v.conversation_id = s.conversation_id and v.direction = s.direction
                                     and v.body not like '[Summary by Eggsy%'
                                     and abs(extract(epoch from v.sent_at - s.sent_at)) < 7200)),
         exists (select 1 from public.messages x where x.conversation_id = d.conversation_id and x.attachment_missing),
         d.drafted_at
  from public.suggested_drafts d
  where not d.superseded
$function$;

-- 4) Auto-inserting a pending "promised in reply" action must not itself
--    queue the draft (that would double-send once the reply is already queued).
CREATE OR REPLACE FUNCTION public.cx_auto_send_on_action()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF new.status = 'pending'
     AND coalesce(new.details->>'source', '') LIKE 'auto:%' THEN
    RETURN NULL;
  END IF;
  PERFORM public.cx_auto_send_ready(new.conversation_id);
  RETURN NULL;
END
$function$;

GRANT EXECUTE ON FUNCTION public.cx_action_missing_required_details(text, uuid, jsonb) TO postgres, service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.cx_action_types_in_reply(text, boolean) TO postgres, service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.cx_log_promised_actions_from_reply(uuid, text, uuid, uuid) TO postgres, service_role, authenticated;
