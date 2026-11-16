-- Square-bracket notes are only for blocking gaps. Follow-up work becomes a
-- pending cx_actions row (type follow_up) and context goes on suggested_drafts.context.
-- This migration does not update any draft body, so cx_auto_send_on_draft cannot
-- queue a customer reply while it is applied. The backfill is cx_apply_draft_note_split
-- and stays unrun until someone passes p_confirm := true.

CREATE OR REPLACE FUNCTION public.cx_auto_send_on_draft()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
BEGIN
  -- Set eggsy.suppress_auto_send = on for a deployment or an approved rewrite
  -- so an UPDATE of an existing draft cannot queue a customer send.
  IF coalesce(current_setting('eggsy.suppress_auto_send', true), '') IN ('on', 'true', '1') THEN
    RETURN NULL;
  END IF;
  IF NOT new.superseded THEN
    PERFORM public.cx_auto_send_ready(new.conversation_id);
  END IF;
  RETURN NULL;
END
$fn$;

SELECT set_config('eggsy.suppress_auto_send', 'on', true);

ALTER TABLE public.suggested_drafts
  ADD COLUMN IF NOT EXISTS context text;

COMMENT ON COLUMN public.suggested_drafts.context IS
  'Internal context for the person reading the ticket. Not part of the customer reply and not counted by cx_draft_readiness().';

ALTER TABLE public.cx_actions DROP CONSTRAINT IF EXISTS cx_actions_type_check;
ALTER TABLE public.cx_actions ADD CONSTRAINT cx_actions_type_check
  CHECK (type = ANY (ARRAY['replacement'::text, 'refund'::text, 'return'::text, 'sample'::text, 'follow_up'::text]));

COMMENT ON TABLE public.cx_actions IS
  'Customer replacements, refunds, returns, samples, and internal follow-up tasks linked to a ticket.';

CREATE INDEX IF NOT EXISTS cx_actions_follow_up_open_idx
  ON public.cx_actions (created_at DESC)
  WHERE type = 'follow_up' AND status = ANY (ARRAY['pending'::text, 'created'::text]);

CREATE OR REPLACE FUNCTION public.cx_follow_up_owner(p_note text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $fn$
  SELECT CASE
    WHEN split_part(coalesce(p_note, ''), ':', 1) ~* '(^|[ /])marketing|influencer|creator' THEN 'marketing'
    WHEN split_part(coalesce(p_note, ''), ':', 1) ~* 'director|founder' THEN 'directors'
    WHEN split_part(coalesce(p_note, ''), ':', 1) ~* 'warehouse' THEN 'warehouse'
    WHEN split_part(coalesce(p_note, ''), ':', 1) ~* 'product|games team|design' THEN 'product'
    WHEN split_part(coalesce(p_note, ''), ':', 1) ~* '\msales\M' THEN 'sales'
    WHEN split_part(coalesce(p_note, ''), ':', 1) ~* 'finance' THEN 'finance'
    WHEN split_part(coalesce(p_note, ''), ':', 1) ~* 'hiring|recruit' THEN 'ops'
    WHEN split_part(coalesce(p_note, ''), ':', 1) ~* '\mops\M' THEN 'ops'
    WHEN coalesce(p_note, '') ~* '\m(marketing|influencer|creator|sponsorship|press request)\M' THEN 'marketing'
    WHEN coalesce(p_note, '') ~* '\m(warehouse|3pl|finishing line)\M' THEN 'warehouse'
    WHEN coalesce(p_note, '') ~* '(games team|illustrat)' THEN 'product'
    WHEN coalesce(p_note, '') ~* '\mdirector' THEN 'directors'
    WHEN coalesce(p_note, '') ~* '\m(distributor|reseller|wholesale)\M' THEN 'sales'
    WHEN coalesce(p_note, '') ~* '\mfinance\M' THEN 'finance'
    WHEN coalesce(p_note, '') ~* '\m(hiring|recruitment|recruit)\M' THEN 'ops'
    WHEN coalesce(p_note, '') ~* '\mops\M' THEN 'ops'
    ELSE 'cx'
  END
$fn$;

CREATE OR REPLACE FUNCTION public.cx_classify_bracket_note(p_note text, p_placement text DEFAULT 'leading')
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $fn$
DECLARE
  n text := btrim(coalesce(p_note, ''));
  l text := lower(n);
  place text := lower(coalesce(p_placement, 'leading'));
  reply_edit boolean;
  approval boolean;
  dont_send boolean;
BEGIN
  IF n = '' THEN
    RETURN jsonb_build_object('class','info','owner_team',null,'description',null,'reason','empty bracket');
  END IF;

  reply_edit := l ~ '(where marked|keep paragraph|keep the matching|delete the other|replace the middle|replace the cancel|rewrite (the|this)|edit (this|the) (\w+ )?(reply|draft)|change (the|this) reply|update this reply|add the (current |tracking)|add it (where|below)|second paragraph|edit or delete|put the correct)';
  approval := l ~ '(us refund|eu refund|partial refund|re-send or refund|resend or refund|remedy decision|don''t promise|do not promise|do not confirm the|don''t give a dispatch|do not give a dispatch|must be (verified|checked|confirmed)|a person must approve|must approve|unverified|not confirmed yet|undefined|not defined|no solution may be guessed|don''t assume|do not assume|cannot auto-send|amazon_not_plain|human review|games-team assessment|if it is all handled)';
  dont_send := l ~ '(do not reply|don''t reply|no-reply address|no reply is appropriate|must not receive a reply|don''t send anything|do not send anything|nothing to send|delete this draft|already replied|already answered|someone may already have answered|mark the ticket resolved|mark this ticket|if a teammate has already|if someone already)';

  -- A short bracket inside the customer sentences is a hole in the reply.
  IF place IN ('mid_reply','trailing')
     AND length(n) < 240
     AND l !~ '^(need:|check |hatty|marketing|ops/|sales:|influencer)' THEN
    RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason','phrase sits in the customer reply');
  END IF;

  -- A finished holding reply can go out. The internal decision is a follow-up.
  IF l ~ 'holding reply' AND NOT reply_edit AND NOT approval THEN
    RETURN jsonb_build_object('class','follow_up','owner_team',public.cx_follow_up_owner(n),'description',n,'reason','holding reply is already the customer message');
  END IF;

  IF reply_edit OR (l ~ 'then delete this note' AND l ~ '(add |edit |change the|change this|keep the|rewrite|replace the|paragraph|put the|in the reply|update this reply)') THEN
    RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason','the reply still has a gap or a choice of wording');
  END IF;

  IF approval OR dont_send THEN
    RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason',
      CASE WHEN dont_send AND NOT approval THEN 'confirm before sending another reply' ELSE 'a fact or approval still changes what we tell the customer' END);
  END IF;

  IF l ~ '^need:' THEN
    IF l ~ 'send channel is disabled'
       AND l ~ 'send route'
       AND l !~ '(human review|assessment|verif|policy|refund|photo|guess|stock|language|price)' THEN
      RETURN jsonb_build_object('class','info','owner_team',null,'description',null,'reason','send route is off; the reply text has no gap');
    END IF;
    RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason','open need before the reply is safe to say');
  END IF;

  IF l ~ '(then answer|answer (her|his|their) question|same game or not)' THEN
    RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason','the reply still depends on a fact');
  END IF;

  IF l ~ 'place the (free )?replacement'
     AND l ~ '(must approve|person must|\musd\M|\meur\M|delivered|no earlier|tracking)' THEN
    RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason','replacement is not confirmed yet');
  END IF;

  IF l ~ '(and decide[, ]|decide whether|decide, then)' AND l !~ 'holding reply' THEN
    RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason','a decision still changes the reply');
  END IF;

  IF l ~ '(follow up|follow-up|\mpass (on|the|this|it)\M|\mforward\M|log (a|the) sample|update (the )?(kb|knowledge)|\mchase\M|place the (free )?replacement|let marketing|close the pending|no replacement is needed)'
     OR (l ~ 'once (she|he|they) repl' AND l ~ 'before arranging')
     OR (
       l ~ '(marketing|influencer|creator|sample request)'
       AND l ~ 'then delete this note'
       AND l !~ '(decide whether|never promise|before sending|\mdecide\M)'
     ) THEN
    RETURN jsonb_build_object('class','follow_up','owner_team',public.cx_follow_up_owner(n),'description',n,'reason','internal follow-up; the reply does not depend on it');
  END IF;

  IF l ~ '^(check|confirm|hatty)' AND l ~ '(add |edit |change |keep |offer |promise|before sending|rewrite|paragraph|correct email)' THEN
    RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason','check changes the reply');
  END IF;

  IF l ~ 'before sending' AND l ~ '(spare|in stock|available|correct email|bounce)' THEN
    RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason','a fact is still missing before we say this');
  END IF;

  IF l ~ '^(fyi|for context|note:)' AND l !~ '(check |send |decid|reply|confirm)' THEN
    RETURN jsonb_build_object('class','info','owner_team',null,'description',null,'reason','context only');
  END IF;

  RETURN jsonb_build_object('class','blocking','owner_team',null,'description',null,'reason','not clearly a follow-up or context note');
END
$fn$;

-- Customer text only (brackets stripped). A reply that says a remedy is already
-- done still needs a logged action. A promise to arrange one does not.
CREATE OR REPLACE FUNCTION public.cx_reply_claims_done(p_body text)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $fn$
DECLARE
  b text := regexp_replace(coalesce(p_body, ''), '\[[^\]]*\]', '', 'g');
  types text[] := '{}';
BEGIN
  IF (
       b ~* '(we[''’]ve|we have) (already )?(fully )?(refunded|issued (a |the |your )?refund|processed (the |your )?refund)'
       OR b ~* 'refund has (now |already )?been (processed|issued|completed|paid|sent)'
       OR b ~* '(your|the) refund (has|is) (now |already )?(been )?(processed|issued|completed|paid)'
     )
     AND b !~* '(if|once|when|whether|until|before) .{0,40}refund'
     AND b !~* '(not|haven''t|have not|has not|hasn''t) .{0,30}refund' THEN
    types := array_append(types, 'refund');
  END IF;
  IF (
       b ~* '(we[''’]ve|we have) (already )?(sent|dispatched|shipped|posted) (you |the |your )?(a |the |free )?replacement'
       OR b ~* 'replacement has (now |already )?been (sent|dispatched|shipped|posted)'
     )
     AND b !~* '(if|once|when|whether|until|before) .{0,40}replacement'
     AND b !~* '(not|haven''t|have not) .{0,30}(sent|dispatched|shipped).{0,30}replacement' THEN
    types := array_append(types, 'replacement');
  END IF;
  IF (
       b ~* '(we[''’]ve|we have) (already )?received (your|the) return'
       OR b ~* '(your|the) return has (now |already )?been received'
     )
     AND b !~* '(if|once|when|whether|until) .{0,30}return' THEN
    types := array_append(types, 'return');
  END IF;
  RETURN types;
END
$fn$;

-- missing_actions is only an open Ask-Marty follow-up, or a replacement / refund /
-- return the reply says is already done and that is not logged. Pending follow_up
-- tasks are not included and do not block auto-send.
CREATE OR REPLACE FUNCTION public.cx_draft_missing_actions(p_conversation uuid, p_body text)
RETURNS text[]
LANGUAGE sql
STABLE
SET search_path TO ''
AS $fn$
  SELECT coalesce(array_agg(t ORDER BY t), '{}'::text[])
  FROM (
    SELECT 'marty'::text AS t
    WHERE EXISTS (
      SELECT 1 FROM public.cx_followups f
      WHERE f.conversation_id = p_conversation
        AND f.kind = 'advice'
        AND f.status = 'open'
    )
    UNION
    SELECT u
    FROM unnest(public.cx_reply_claims_done(p_body)) AS u
    WHERE NOT EXISTS (
      SELECT 1 FROM public.cx_actions a
      WHERE a.conversation_id = p_conversation
        AND a.type = u
        AND a.status IN ('created', 'done', 'expected', 'received')
    )
  ) s
$fn$;

CREATE OR REPLACE FUNCTION public.cx_draft_readiness()
RETURNS TABLE(conversation_id uuid, notes integer, missing_actions text[], partial_history boolean, attachment_missing boolean, drafted_at timestamp with time zone)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $fn$
  SELECT d.conversation_id,
         coalesce((SELECT count(*)::int FROM regexp_matches(d.body, '\[[^\]]*\]', 'g')), 0),
         public.cx_draft_missing_actions(d.conversation_id, d.body),
         EXISTS (
           SELECT 1 FROM public.messages s
           WHERE s.conversation_id = d.conversation_id
             AND s.direction::text IN ('inbound', 'outbound')
             AND s.body LIKE '[Summary by Eggsy%'
             AND NOT EXISTS (
               SELECT 1 FROM public.messages v
               WHERE v.conversation_id = s.conversation_id
                 AND v.direction = s.direction
                 AND v.body NOT LIKE '[Summary by Eggsy%'
                 AND abs(extract(epoch FROM v.sent_at - s.sent_at)) < 7200
             )
         ),
         EXISTS (
           SELECT 1 FROM public.messages x
           WHERE x.conversation_id = d.conversation_id
             AND x.attachment_missing
         ),
         d.drafted_at
  FROM public.suggested_drafts d
  WHERE NOT d.superseded
$fn$;

COMMENT ON FUNCTION public.cx_draft_readiness() IS
  'notes counts [brackets] in the customer draft only. suggested_drafts.context is not counted. missing_actions is an open Marty advice follow-up, or a remedy the reply says is already done. Pending follow_up actions do not appear here.';

CREATE OR REPLACE FUNCTION public.cx_split_draft_notes(p_body text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $fn$
DECLARE
  src text := coalesce(p_body, '');
  raw text;
  n text;
  pos int;
  after text;
  placement text;
  cls jsonb;
  new_body text := src;
  infos text[] := '{}';
  acts jsonb := '[]'::jsonb;
  out_notes jsonb := '[]'::jsonb;
  seen text[] := '{}';
  desc_text text;
  rec record;
BEGIN
  FOR rec IN
    SELECT m[1] AS raw, ord
    FROM regexp_matches(src, '\[([^\]]*)\]', 'g') WITH ORDINALITY AS r(m, ord)
    ORDER BY ord
  LOOP
    raw := rec.raw;
    n := btrim(raw);
    pos := strpos(src, '[' || raw || ']');
    after := substring(src FROM pos + char_length(raw) + 2);
    after := regexp_replace(after, '\[[^\]]*\]', '', 'g');
    after := regexp_replace(after, '(Best regards,|Kind regards,|Cordialement,|Saludos cordiales,|Un saludo,|Cordiali saluti,|Mit freundlichen Grüßen,)[\s\S]*$', '', 'i');
    IF pos <= 5 THEN
      placement := 'leading';
    ELSIF length(btrim(after)) > 40 THEN
      placement := 'mid_reply';
    ELSE
      placement := 'trailing';
    END IF;

    cls := public.cx_classify_bracket_note(n, placement);
    out_notes := out_notes || jsonb_build_array(cls || jsonb_build_object('note', n, 'placement', placement));

    IF cls->>'class' IN ('follow_up', 'info') THEN
      new_body := replace(new_body, '[' || raw || ']', '');
    END IF;
    IF cls->>'class' = 'info' AND n <> '' THEN
      infos := array_append(infos, n);
    ELSIF cls->>'class' = 'follow_up' THEN
      desc_text := coalesce(cls->>'description', n);
      IF desc_text <> '' AND NOT (desc_text = ANY (seen)) THEN
        seen := array_append(seen, desc_text);
        acts := acts || jsonb_build_array(jsonb_build_object(
          'description', desc_text,
          'owner_team', coalesce(cls->>'owner_team', 'cx')
        ));
      END IF;
    END IF;
  END LOOP;

  new_body := regexp_replace(new_body, E'[ \t]+\n', E'\n', 'g');
  new_body := regexp_replace(new_body, E'\n{3,}', E'\n\n', 'g');
  new_body := regexp_replace(new_body, '^[[:space:]]+|[[:space:]]+$', '', 'g');

  RETURN jsonb_build_object(
    'body', new_body,
    'context', nullif(array_to_string(infos, E'\n\n'), ''),
    'actions', acts,
    'notes', out_notes
  );
END
$fn$;

-- Same decision as cx_queue_ready_draft, for a proposed body. Never writes and never queues.
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

  RETURN 'queued';
END
$fn$;

COMMENT ON FUNCTION public.cx_auto_send_preview(uuid, text, integer) IS
  'Read-only twin of cx_queue_ready_draft for a proposed body. queued means the real function would insert a reply. This function never writes.';

CREATE OR REPLACE FUNCTION public.cx_draft_note_split_report()
RETURNS TABLE(
  conversation_id uuid,
  customer text,
  channel text,
  note_ord integer,
  note text,
  placement text,
  proposed_class text,
  proposed_action text,
  owner_team text,
  reason text,
  notes_before integer,
  notes_after integer,
  would_auto_send boolean,
  hold text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
BEGIN
  RETURN QUERY
  WITH drafts AS (
    SELECT DISTINCT ON (d.conversation_id)
           d.conversation_id,
           d.body,
           coalesce(c.customer_name, c.customer_handle, '') AS customer,
           c.origin::text AS channel
      FROM public.suggested_drafts d
      JOIN public.conversations c ON c.id = d.conversation_id
      JOIN public.cx_conversation_state st ON st.conversation_id = d.conversation_id
     WHERE NOT d.superseded
       AND st.bucket = 'inbox'
       AND d.body ~ '\[[^\]]*\]'
     ORDER BY d.conversation_id, d.drafted_at DESC
  ),
  split AS (
    SELECT drafts.*, public.cx_split_draft_notes(drafts.body) AS s
      FROM drafts
  ),
  previewed AS (
    SELECT split.*, public.cx_auto_send_preview(split.conversation_id, split.s->>'body') AS hold_reason
      FROM split
  )
  SELECT p.conversation_id,
         p.customer,
         p.channel,
         n.ord::integer,
         n.note->>'note',
         n.note->>'placement',
         n.note->>'class',
         CASE WHEN n.note->>'class' = 'follow_up' THEN n.note->>'description' ELSE NULL END,
         CASE WHEN n.note->>'class' = 'follow_up' THEN n.note->>'owner_team' ELSE NULL END,
         n.note->>'reason',
         coalesce(jsonb_array_length(p.s->'notes'), 0),
         coalesce((SELECT count(*)::int FROM regexp_matches(p.s->>'body', '\[[^\]]*\]', 'g')), 0),
         p.hold_reason = 'queued',
         p.hold_reason
    FROM previewed p
    CROSS JOIN LATERAL jsonb_array_elements(p.s->'notes') WITH ORDINALITY AS n(note, ord)
   ORDER BY p.channel, p.customer, p.conversation_id, n.ord;
END
$fn$;

COMMENT ON FUNCTION public.cx_draft_note_split_report() IS
  'Dry run for Inbox bracket notes. Reads drafts and returns a class per note. Does not update drafts and does not queue replies.';

CREATE OR REPLACE FUNCTION public.cx_save_draft(
  p_conversation_id uuid,
  p_body text,
  p_blocking_notes text[] DEFAULT '{}'::text[],
  p_follow_up_actions jsonb DEFAULT '[]'::jsonb,
  p_context text DEFAULT NULL,
  p_language text DEFAULT NULL,
  p_body_en text DEFAULT NULL,
  p_author text DEFAULT 'Eggsy'
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
  allowed text[] := ARRAY['marketing','warehouse','product','cx','directors','ops','sales','finance'];
BEGIN
  IF jwt_role = 'anon' OR (jwt_role = 'authenticated' AND NOT public.is_lucky_egg_staff()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_conversation_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = p_conversation_id) THEN
    RAISE EXCEPTION 'conversation not found';
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

  -- Superseding the previous draft does not auto-send (the trigger requires NOT superseded).
  UPDATE public.suggested_drafts
     SET superseded = true,
         superseded_at = now()
   WHERE conversation_id = p_conversation_id
     AND NOT superseded;

  INSERT INTO public.suggested_drafts (conversation_id, body, body_en, language, author, context)
  VALUES (
    p_conversation_id,
    body,
    nullif(btrim(coalesce(p_body_en, '')), ''),
    lang,
    coalesce(nullif(btrim(p_author), ''), 'Eggsy'),
    ctx
  )
  RETURNING id INTO draft_id;

  IF jsonb_typeof(coalesce(p_follow_up_actions, '[]'::jsonb)) = 'array' THEN
    FOR act IN SELECT value FROM jsonb_array_elements(p_follow_up_actions) LOOP
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
      -- source auto: so cx_auto_send_on_action does not queue from this insert.
      INSERT INTO public.cx_actions (conversation_id, type, status, details, created_by)
      VALUES (
        p_conversation_id,
        'follow_up',
        'pending',
        jsonb_build_object(
          'description', desc_text,
          'owner_team', team,
          'source', 'auto:draft-follow-up',
          'draft_id', draft_id
        ),
        'Eggsy (draft follow-up)'
      );
    END LOOP;
  END IF;

  RETURN draft_id;
END
$fn$;

COMMENT ON FUNCTION public.cx_save_draft(uuid, text, text[], jsonb, text, text, text, text) IS
  'Save an Eggsy draft. Brackets are added only for p_blocking_notes. p_follow_up_actions is a jsonb array of {description, owner_team} and becomes pending follow_up actions (they do not block auto-send). p_context is the internal note shown above the reply and is not counted as a bracket.';

CREATE OR REPLACE FUNCTION public.cx_apply_draft_note_split(p_confirm boolean DEFAULT false, p_queue boolean DEFAULT false)
RETURNS TABLE(
  conversation_id uuid,
  customer text,
  notes_before integer,
  notes_after integer,
  follow_ups_added integer,
  context_set boolean,
  preview text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  jwt_role text := coalesce(current_setting('request.jwt.claim.role', true), '');
  rec record;
  split jsonb;
  new_body text;
  new_context text;
  new_en text;
  item jsonb;
  added integer;
  desc_text text;
  team text;
  allowed text[] := ARRAY['marketing','warehouse','product','cx','directors','ops','sales','finance'];
  touched uuid[] := '{}';
  cid uuid;
BEGIN
  IF NOT coalesce(p_confirm, false) THEN
    RAISE EXCEPTION 'Refusing to rewrite live drafts. Review public.cx_draft_note_split_report(), then call public.cx_apply_draft_note_split(true, false). The rewrite suppresses auto-send. Pass true as the second argument only when ready drafts should also be queued through the existing safety holds.';
  END IF;
  IF jwt_role IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'Run cx_apply_draft_note_split from the database as postgres or service_role, after the dry run is approved.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM set_config('eggsy.suppress_auto_send', 'on', true);

  FOR rec IN
    SELECT d.id,
           d.conversation_id,
           d.body,
           d.body_en,
           d.context,
           coalesce(c.customer_name, c.customer_handle, '') AS customer_name
      FROM public.suggested_drafts d
      JOIN public.conversations c ON c.id = d.conversation_id
      JOIN public.cx_conversation_state st ON st.conversation_id = d.conversation_id
     WHERE NOT d.superseded
       AND st.bucket = 'inbox'
       AND d.body ~ '\[[^\]]*\]'
     ORDER BY d.conversation_id
       FOR UPDATE OF d
  LOOP
    split := public.cx_split_draft_notes(rec.body);
    new_body := split->>'body';
    new_context := nullif(btrim(concat_ws(
      E'\n\n',
      nullif(btrim(coalesce(rec.context, '')), ''),
      nullif(btrim(coalesce(split->>'context', '')), '')
    )), '');
    new_en := rec.body_en;
    added := 0;

    IF new_en IS NOT NULL AND jsonb_typeof(split->'notes') = 'array' THEN
      FOR item IN SELECT value FROM jsonb_array_elements(split->'notes') LOOP
        IF item->>'class' IN ('follow_up', 'info') AND coalesce(item->>'note', '') <> '' THEN
          new_en := replace(new_en, '[' || (item->>'note') || ']', '');
        END IF;
      END LOOP;
      new_en := regexp_replace(regexp_replace(regexp_replace(coalesce(new_en, ''), E'[ \t]+\n', E'\n', 'g'), E'\n{3,}', E'\n\n', 'g'), '^[[:space:]]+|[[:space:]]+$', '', 'g');
      IF new_en = '' THEN
        new_en := NULL;
      END IF;
    END IF;

    IF new_body IS DISTINCT FROM rec.body
       OR new_context IS DISTINCT FROM rec.context
       OR new_en IS DISTINCT FROM rec.body_en THEN
      UPDATE public.suggested_drafts
         SET body = new_body,
             body_en = new_en,
             context = new_context
       WHERE id = rec.id;
    END IF;

    IF jsonb_typeof(split->'actions') = 'array' THEN
      FOR item IN SELECT value FROM jsonb_array_elements(split->'actions') LOOP
        desc_text := btrim(coalesce(item->>'description', ''));
        IF desc_text = '' THEN
          CONTINUE;
        END IF;
        team := lower(btrim(coalesce(item->>'owner_team', 'cx')));
        IF NOT (team = ANY (allowed)) THEN
          team := 'cx';
        END IF;
        IF EXISTS (
          SELECT 1 FROM public.cx_actions a
           WHERE a.conversation_id = rec.conversation_id
             AND a.type = 'follow_up'
             AND a.status IN ('pending', 'created')
             AND a.details->>'description' = desc_text
        ) THEN
          CONTINUE;
        END IF;
        INSERT INTO public.cx_actions (conversation_id, type, status, details, created_by)
        VALUES (
          rec.conversation_id,
          'follow_up',
          'pending',
          jsonb_build_object(
            'description', desc_text,
            'owner_team', team,
            'source', 'auto:draft-follow-up',
            'draft_id', rec.id
          ),
          'Eggsy (draft follow-up)'
        );
        added := added + 1;
      END LOOP;
    END IF;

    touched := array_append(touched, rec.conversation_id);
    conversation_id := rec.conversation_id;
    customer := rec.customer_name;
    notes_before := coalesce(jsonb_array_length(split->'notes'), 0);
    notes_after := coalesce((SELECT count(*)::int FROM regexp_matches(new_body, '\[[^\]]*\]', 'g')), 0);
    follow_ups_added := added;
    context_set := new_context IS NOT NULL;
    preview := public.cx_auto_send_preview(rec.conversation_id, new_body);
    RETURN NEXT;
  END LOOP;

  IF coalesce(p_queue, false) THEN
    PERFORM set_config('eggsy.suppress_auto_send', 'off', true);
    FOREACH cid IN ARRAY touched LOOP
      PERFORM public.cx_queue_ready_draft(cid);
    END LOOP;
  END IF;

  RETURN;
END
$fn$;

COMMENT ON FUNCTION public.cx_apply_draft_note_split(boolean, boolean) IS
  'Rewrites Inbox drafts from the bracket-note classifier. Refuses to run unless p_confirm is true. Suppresses auto-send during the rewrite. p_queue true afterwards calls cx_queue_ready_draft, which still applies every existing safety hold.';

CREATE OR REPLACE FUNCTION public.cx_bucket_counts()
RETURNS json
LANGUAGE sql
STABLE
SET search_path TO ''
AS $fn$
  SELECT json_build_object(
    'inbox', count(*) FILTER (WHERE bucket = 'inbox'),
    'waiting', count(*) FILTER (WHERE bucket = 'waiting'),
    'resolved', count(*) FILTER (WHERE bucket = 'resolved'),
    'junk', count(*) FILTER (WHERE bucket = 'junk'),
    'actions', (
      SELECT count(*) FROM public.cx_followups WHERE status = 'open'
    ) + (
      SELECT count(*) FROM public.cx_actions
       WHERE type = 'follow_up' AND status IN ('pending', 'created')
    ),
    'queue', (
      SELECT count(*) FROM public.reply_queue WHERE status IN ('queued', 'sending')
    )
  )
  FROM public.cx_conversation_state
$fn$;

REVOKE ALL ON FUNCTION public.cx_follow_up_owner(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cx_classify_bracket_note(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cx_reply_claims_done(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cx_draft_missing_actions(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cx_split_draft_notes(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cx_auto_send_preview(uuid, text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cx_draft_note_split_report() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cx_save_draft(uuid, text, text[], jsonb, text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cx_apply_draft_note_split(boolean, boolean) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.cx_follow_up_owner(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cx_classify_bracket_note(text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cx_reply_claims_done(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cx_draft_missing_actions(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cx_split_draft_notes(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cx_auto_send_preview(uuid, text, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cx_draft_note_split_report() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cx_save_draft(uuid, text, text[], jsonb, text, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cx_apply_draft_note_split(boolean, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.cx_draft_readiness() TO authenticated, service_role;

DO $kb$
DECLARE
  n integer;
  section text := $txt$

## Square-bracket notes (16 Nov 2026)

Square brackets in a draft are only for a **blocking** gap. Use one when the customer-facing reply is missing a fact, or a decision would change the words we send. Examples: the order lookup is not back yet, stock or a delivery date is unknown, a policy choice changes the reply, or a person must approve it first (US and EU refunds). Those brackets keep the draft in Gaps and stop auto-send.

Do not put an internal to-do in brackets when the reply is already accurate. Passing it to marketing, sending the replacement the reply says we will arrange, checking with the warehouse and following up, updating the knowledge base, logging a sample, or chasing another team is a **follow-up**. Save it with `cx_save_draft` as a follow-up action: a description, an owner team (`marketing`, `warehouse`, `product`, `cx`, `directors`, `ops`, `sales`, or `finance`), status pending, linked to the conversation. A pending follow-up does not block auto-send.

A note that is only context for the person reading the ticket, with no gap and no job, goes in the draft **context** field. It is shown above the reply and is not counted as a bracket note.

Save a draft like this:

```sql
select public.cx_save_draft(
  '<conversation uuid>'::uuid,
  '<customer reply, with no brackets>',
  ARRAY['<blocking gap>']::text[],
  '[{"description":"<what to do>","owner_team":"marketing"}]'::jsonb,
  '<internal context, or null>'
);
```

Leave the blocking-notes array empty when there is no gap. Auto-send still holds US/EU refund escalation, a reply that already went out, Amazon text that is not plain, flags, junk, a missing photo, and a chat that is only an Eggsy summary.
$txt$;
BEGIN
  UPDATE public.kb_articles
     SET body = body || section
   WHERE title = 'How we write replies: tone, structure and sign-off'
     AND body NOT LIKE '%## Square-bracket notes (16 Nov 2026)%';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 AND NOT EXISTS (
    SELECT 1 FROM public.kb_articles
     WHERE title = 'How we write replies: tone, structure and sign-off'
       AND body LIKE '%## Square-bracket notes (16 Nov 2026)%'
  ) THEN
    RAISE NOTICE 'Drafting KB article was not updated. The convention is also in docs/drafting.md.';
  END IF;
END
$kb$;

DO $check$
BEGIN
  IF (public.cx_classify_bracket_note(
        'Marketing/directors: CDH Racing sponsorship pitch for 2027. Delete this draft if not interested, or send this holding reply and follow up.',
        'leading')->>'class') IS DISTINCT FROM 'follow_up' THEN
    RAISE EXCEPTION 'CDH holding reply should be a follow-up';
  END IF;
  IF (public.cx_classify_bracket_note(
        'Marketing/directors: CDH Racing sponsorship pitch for 2027. Delete this draft if not interested, or send this holding reply and follow up.',
        'leading')->>'owner_team') IS DISTINCT FROM 'marketing' THEN
    RAISE EXCEPTION 'CDH follow-up should be owned by marketing';
  END IF;
  IF (public.cx_classify_bracket_note('carrier and tracking number', 'mid_reply')->>'class') IS DISTINCT FROM 'blocking' THEN
    RAISE EXCEPTION 'tracking fill-in should stay blocking';
  END IF;
  IF (public.cx_classify_bracket_note(
        'Need: Wix new-email send channel is disabled. Customer reply requires an enabled/authorised send route, not a direct-send bypass.',
        'leading')->>'class') IS DISTINCT FROM 'info' THEN
    RAISE EXCEPTION 'disabled send route should be context';
  END IF;
  IF (public.cx_classify_bracket_note(
        'Hatty/Kim: Amazon DE remedy decision. Do not promise a refund until they decide.',
        'leading')->>'class') IS DISTINCT FROM 'blocking' THEN
    RAISE EXCEPTION 'EU remedy approval should stay blocking';
  END IF;
  IF (public.cx_classify_bracket_note('article number - name - pieces per pallet', 'trailing')->>'class') IS DISTINCT FROM 'blocking' THEN
    RAISE EXCEPTION 'pallet fill-in should stay blocking';
  END IF;
END
$check$;
