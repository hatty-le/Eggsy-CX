-- Holding reply drafted when a ticket is forwarded to a colleague.
-- The customer text is a draft only. A leading bracket keeps cx_draft_readiness
-- in Gaps, so cx_queue_ready_draft / eggsy-auto does not queue or send it.
-- An existing unsent draft is left in place. The holding text is offered instead.

CREATE OR REPLACE FUNCTION public.cx_holding_reply_text(
  p_origin text,
  p_language text,
  p_sample text
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $fn$
DECLARE
  raw text := lower(btrim(coalesce(p_language, '')));
  code text;
  lang text;
  sample text := coalesce(p_sample, '');
  looks boolean;
  hits int;
  body text;
  english text := 'Hi there, thanks for your message. We''ll get back to you on this shortly.';
BEGIN
  code := CASE raw
    WHEN 'german' THEN 'de'
    WHEN 'french' THEN 'fr'
    WHEN 'spanish' THEN 'es'
    WHEN 'italian' THEN 'it'
    WHEN 'dutch' THEN 'nl'
    WHEN 'english' THEN 'en'
    ELSE left(raw, 2)
  END;

  looks := sample ~ '[äöüÄÖÜßàâçéèêëïîôùûœìíóúñ¿¡]';
  IF NOT looks AND sample <> '' THEN
    SELECT count(*) INTO hits
      FROM regexp_matches(lower(sample), '\m(und|ich|nicht|bitte|danke|vielen|hallo|sie|ihre|bonjour|merci|vous|hola|gracias|buongiorno|grazie|bedankt|dank|bestellung|commande|pedido)\M', 'g');
    looks := coalesce(hits, 0) >= 2;
  END IF;

  IF code = 'en' THEN
    lang := 'en';
  ELSIF code IN ('de', 'fr', 'es', 'it', 'nl') THEN
    lang := code;
  ELSIF sample <> '' AND NOT looks THEN
    lang := 'en';
  ELSE
    lang := CASE lower(coalesce(p_origin, ''))
      WHEN 'amazon_de' THEN 'de'
      WHEN 'amazon_fr' THEN 'fr'
      WHEN 'amazon_it' THEN 'it'
      WHEN 'amazon_es' THEN 'es'
      WHEN 'amazon_nl' THEN 'nl'
      WHEN 'tiktok_eu' THEN 'de'
      ELSE 'en'
    END;
  END IF;

  body := CASE lang
    WHEN 'de' THEN 'Hallo, vielen Dank für Ihre Nachricht. Wir melden uns in Kürze bei Ihnen.'
    WHEN 'fr' THEN 'Bonjour, merci pour votre message. Nous vous répondrons très prochainement.'
    WHEN 'es' THEN 'Hola, gracias por su mensaje. Le responderemos en breve.'
    WHEN 'it' THEN 'Ciao, grazie per il suo messaggio. Le risponderemo a breve.'
    WHEN 'nl' THEN 'Hallo, bedankt voor uw bericht. We nemen hier binnenkort contact met u over op.'
    ELSE english
  END;

  -- Plain text only: no links or brackets. The sentences above have no emoji.
  IF body ~ 'https?://|www\.|\[|\]' THEN
    RAISE EXCEPTION 'holding reply must stay plain text';
  END IF;

  RETURN jsonb_build_object(
    'language', lang,
    'body', body,
    'body_en', CASE WHEN lang = 'en' THEN NULL ELSE english END
  );
END
$fn$;

COMMENT ON FUNCTION public.cx_holding_reply_text(text, text, text) IS
  'Customer-facing holding reply in the language Eggsy already uses for that ticket. English when the language is not one the reply box knows. Plain text, no links or emoji.';

CREATE OR REPLACE FUNCTION public.cx_place_holding_reply(
  p_conversation uuid,
  p_replace boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  jwt_role text := coalesce(current_setting('request.jwt.claim.role', true), '');
  origin text;
  sample_lang text;
  sample_body text;
  reply jsonb;
  customer text;
  stored text;
  lang text;
  body_en text;
  last_out timestamptz;
  existing_id uuid;
  existing_body text;
  existing_author text;
  existing_at timestamptz;
  msg_body text;
  msg_at timestamptz;
  visible text;
  draft_id uuid;
  draft_superseded boolean;
  blocked int;
BEGIN
  IF jwt_role = 'anon'
     OR (jwt_role = 'authenticated' AND NOT public.is_lucky_egg_staff()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_conversation IS NULL THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  SELECT c.origin::text INTO origin
    FROM public.conversations c
   WHERE c.id = p_conversation;
  IF origin IS NULL THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  SELECT m.language, m.body INTO sample_lang, sample_body
    FROM public.messages m
   WHERE m.conversation_id = p_conversation
     AND m.direction = 'inbound'
     AND coalesce(m.body, '') !~ '^\[Summary by Eggsy'
   ORDER BY m.sent_at DESC
   LIMIT 1;

  reply := public.cx_holding_reply_text(origin, sample_lang, sample_body);
  customer := reply->>'body';
  lang := reply->>'language';
  body_en := nullif(reply->>'body_en', '');
  -- The bracket is not part of the reply. It keeps the draft in Gaps so eggsy-auto will not queue it.
  stored := '[Cannot auto-send. A person must approve sending this.]' || E'\n\n' || customer;

  SELECT GREATEST(
           coalesce((SELECT max(m.sent_at) FROM public.messages m
                      WHERE m.conversation_id = p_conversation AND m.direction = 'outbound'), '-infinity'::timestamptz),
           coalesce((SELECT max(q.queued_at) FROM public.reply_queue q
                      WHERE q.conversation_id = p_conversation), '-infinity'::timestamptz)
         )
    INTO last_out;

  SELECT d.id, d.body, d.author, d.drafted_at
    INTO existing_id, existing_body, existing_author, existing_at
    FROM public.suggested_drafts d
   WHERE d.conversation_id = p_conversation
     AND NOT d.superseded
   ORDER BY d.drafted_at DESC
   LIMIT 1;

  IF existing_id IS NOT NULL AND existing_at <= last_out THEN
    existing_id := NULL;
    existing_body := NULL;
    existing_author := NULL;
  END IF;

  IF existing_id IS NULL THEN
    SELECT m.body, m.sent_at INTO msg_body, msg_at
      FROM public.messages m
     WHERE m.conversation_id = p_conversation
       AND m.direction = 'draft'
       AND m.external_id IS DISTINCT FROM 'note:holding-reply-offer'
     ORDER BY m.sent_at DESC
     LIMIT 1;
    IF msg_at IS NOT NULL AND msg_at > last_out THEN
      existing_body := msg_body;
      existing_author := 'message-draft';
    END IF;
  END IF;

  visible := nullif(btrim(regexp_replace(coalesce(existing_body, ''), '\[[^\]]*\]', '', 'g')), '');

  IF existing_body IS NOT NULL AND NOT coalesce(p_replace, false) THEN
    IF existing_author = 'Holding reply' OR visible = customer THEN
      DELETE FROM public.messages
       WHERE conversation_id = p_conversation
         AND external_id = 'note:holding-reply-offer';
      RETURN jsonb_build_object(
        'ok', true,
        'placed', true,
        'kept_draft', false,
        'already', true,
        'language', lang,
        'body', customer
      );
    END IF;

    INSERT INTO public.messages (conversation_id, direction, author, body, sent_at, external_id)
    VALUES (
      p_conversation,
      'note',
      'Holding reply',
      'A holding reply is ready. Your unsent draft was kept. Nothing was sent to the customer.',
      now(),
      'note:holding-reply-offer'
    )
    ON CONFLICT (conversation_id, external_id)
    DO UPDATE SET body = EXCLUDED.body, sent_at = EXCLUDED.sent_at, author = EXCLUDED.author;

    RETURN jsonb_build_object(
      'ok', true,
      'placed', false,
      'kept_draft', true,
      'language', lang,
      'body', customer
    );
  END IF;

  -- Stop the draft-insert trigger from queueing inside this transaction.
  -- The bracket is what stops a later eggsy-auto pass.
  PERFORM set_config('eggsy.suppress_auto_send', 'on', true);

  IF coalesce(p_replace, false) THEN
    UPDATE public.suggested_drafts
       SET superseded = true,
           superseded_at = now()
     WHERE conversation_id = p_conversation
       AND NOT superseded;
  END IF;

  INSERT INTO public.suggested_drafts (conversation_id, body, body_en, language, author, context)
  VALUES (
    p_conversation,
    stored,
    body_en,
    lang,
    'Holding reply',
    'Holding reply drafted. Nothing is sent until you press Send.'
  )
  RETURNING id, superseded INTO draft_id, draft_superseded;

  DELETE FROM public.messages
   WHERE conversation_id = p_conversation
     AND external_id = 'note:holding-reply-offer';

  -- Backstop: this function must never leave the holding text queued.
  DELETE FROM public.reply_queue q
   WHERE q.conversation_id = p_conversation
     AND q.queued_by = 'eggsy-auto'
     AND q.auto_sent IS TRUE
     AND q.status = 'queued'
     AND q.body IN (customer, stored)
     AND q.queued_at >= transaction_timestamp();
  GET DIAGNOSTICS blocked = ROW_COUNT;

  IF coalesce(draft_superseded, false) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'placed', false,
      'kept_draft', false,
      'reason', 'not_shown',
      'language', lang,
      'body', customer,
      'auto_send_blocked', blocked
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'placed', true,
    'kept_draft', false,
    'language', lang,
    'body', customer,
    'draft_id', draft_id,
    'auto_send_blocked', blocked
  );
END
$fn$;

COMMENT ON FUNCTION public.cx_place_holding_reply(uuid, boolean) IS
  'Draft a holding reply after a colleague forward. Does not insert into reply_queue. p_replace false keeps an existing unsent draft and records an offer. p_replace true replaces that draft. The stored body has a bracket so eggsy-auto will not send it.';

REVOKE ALL ON FUNCTION public.cx_holding_reply_text(text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cx_place_holding_reply(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cx_holding_reply_text(text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cx_place_holding_reply(uuid, boolean) TO authenticated, service_role;
