-- Eggsy CX actions layer: replacements, refunds, returns, send guard, metrics.
CREATE TABLE IF NOT EXISTS public.cx_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  type text NOT NULL CHECK (type IN ('replacement', 'refund', 'return')),
  status text NOT NULL CHECK (status IN ('pending', 'created', 'done', 'expected', 'received', 'failed', 'cancelled')),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  shopify_order_id text,
  shopify_order_name text,
  shopify_refund_id text,
  tracking_number text,
  tracking_url text,
  tracking_company text,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

CREATE INDEX IF NOT EXISTS cx_actions_conv_idx
  ON public.cx_actions (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS cx_actions_track_idx
  ON public.cx_actions (type, status)
  WHERE type = 'replacement' AND status = 'created' AND shopify_order_id IS NOT NULL;

COMMENT ON TABLE public.cx_actions IS 'Customer replacements, refunds and returns logged from Eggsy CX tickets.';

ALTER TABLE public.cx_actions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cx_actions_staff_select ON public.cx_actions;
CREATE POLICY cx_actions_staff_select ON public.cx_actions
  FOR SELECT TO authenticated USING (public.is_lucky_egg_staff());
DROP POLICY IF EXISTS cx_actions_staff_insert ON public.cx_actions;
CREATE POLICY cx_actions_staff_insert ON public.cx_actions
  FOR INSERT TO authenticated WITH CHECK (public.is_lucky_egg_staff());
DROP POLICY IF EXISTS cx_actions_staff_update ON public.cx_actions;
CREATE POLICY cx_actions_staff_update ON public.cx_actions
  FOR UPDATE TO authenticated USING (public.is_lucky_egg_staff()) WITH CHECK (public.is_lucky_egg_staff());

ALTER TABLE public.reply_queue
  ADD COLUMN IF NOT EXISTS requires_action boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.cx_promised_action_types(p_body text, p_flag boolean)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $fn$
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
$fn$;

CREATE OR REPLACE FUNCTION public.reply_queue_action_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $fn$
DECLARE
  types text[];
  missing text[] := '{}';
  t text;
  ok boolean;
BEGIN
  IF new.status IS NULL OR new.status NOT IN ('queued', 'sending', 'sent') THEN
    RETURN new;
  END IF;
  IF tg_op = 'UPDATE'
     AND new.status IS NOT DISTINCT FROM old.status
     AND new.body IS NOT DISTINCT FROM old.body
     AND coalesce(new.requires_action, false) IS NOT DISTINCT FROM coalesce(old.requires_action, false) THEN
    RETURN new;
  END IF;
  types := public.cx_promised_action_types(new.body, coalesce(new.requires_action, false));
  IF types IS NULL OR cardinality(types) = 0 THEN
    RETURN new;
  END IF;
  IF types = ARRAY['any'] THEN
    SELECT EXISTS (
      SELECT 1 FROM public.cx_actions a
      WHERE a.conversation_id = new.conversation_id
        AND a.status IN ('created', 'done', 'expected', 'received')
    ) INTO ok;
    IF NOT ok THEN
      RAISE EXCEPTION 'This reply promises a replacement, refund or return, but no matching action is logged on the ticket yet. Create the action first, then send.'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN new;
  END IF;
  FOREACH t IN ARRAY types LOOP
    SELECT EXISTS (
      SELECT 1 FROM public.cx_actions a
      WHERE a.conversation_id = new.conversation_id
        AND a.type = t
        AND a.status IN ('created', 'done', 'expected', 'received')
    ) INTO ok;
    IF NOT ok THEN
      missing := array_append(missing, t);
    END IF;
  END LOOP;
  IF cardinality(missing) > 0 THEN
    RAISE EXCEPTION 'This reply promises a % but no matching action is logged on the ticket yet. Create the % first, then send.',
      array_to_string(missing, ' and '),
      array_to_string(missing, ' and ')
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN new;
END
$fn$;

DROP TRIGGER IF EXISTS reply_queue_action_guard ON public.reply_queue;
CREATE TRIGGER reply_queue_action_guard
  BEFORE INSERT OR UPDATE ON public.reply_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.reply_queue_action_guard();

CREATE OR REPLACE FUNCTION public.cx_log_action_note(p_conversation_id uuid, p_body text, p_external_id text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  nid uuid;
BEGIN
  IF NOT public.is_lucky_egg_staff() THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO public.messages (conversation_id, direction, author, body, sent_at, external_id)
  VALUES (p_conversation_id, 'note', 'Eggsy CX', coalesce(p_body, ''), now(), p_external_id)
  RETURNING id INTO nid;
  RETURN nid;
END
$fn$;

REVOKE ALL ON FUNCTION public.cx_log_action_note(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cx_log_action_note(uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.cx_shopify_admin_token()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
  SELECT decrypted_secret
  FROM vault.decrypted_secrets
  WHERE name = 'shopify_admin_access_token'
  LIMIT 1
$fn$;

REVOKE ALL ON FUNCTION public.cx_shopify_admin_token() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cx_shopify_admin_token() TO service_role;

CREATE OR REPLACE FUNCTION public.cx_action_metrics(p_from date, p_to date)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $fn$
  WITH base AS (
    SELECT a.type, a.status, a.details, a.created_at, c.origin
    FROM public.cx_actions a
    JOIN public.conversations c ON c.id = a.conversation_id
    WHERE (a.created_at AT TIME ZONE 'Europe/London')::date BETWEEN p_from AND p_to
      AND a.status NOT IN ('cancelled', 'failed')
  ),
  grp AS (
    SELECT
      CASE
        WHEN origin::text LIKE 'amazon%' THEN 'amazon'
        WHEN origin::text LIKE 'tiktok%' THEN 'tiktok'
        WHEN origin::text = 'email_hey' THEN 'email'
        WHEN origin::text IN ('shopify_form', 'wix_mmc_form') THEN 'forms'
        WHEN origin::text IN ('facebook', 'instagram') THEN 'meta'
        WHEN origin::text = 'walmart' THEN 'walmart'
        ELSE 'other'
      END AS grp,
      origin,
      count(*) FILTER (WHERE type = 'replacement') AS replacements,
      count(*) FILTER (WHERE type = 'refund') AS refunds,
      count(*) FILTER (WHERE type = 'return') AS returns,
      coalesce(sum(CASE WHEN type = 'refund' THEN coalesce(nullif(details->>'amount', '')::numeric, 0) ELSE 0 END), 0) AS refund_value,
      coalesce(sum(CASE WHEN type = 'replacement' THEN coalesce(nullif(details->>'retail_value', '')::numeric, 0) ELSE 0 END), 0) AS replacement_value
    FROM base
    GROUP BY 1, 2
  )
  SELECT jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'summary', jsonb_build_object(
      'replacements', coalesce((SELECT sum(replacements) FROM grp), 0),
      'refunds', coalesce((SELECT sum(refunds) FROM grp), 0),
      'returns', coalesce((SELECT sum(returns) FROM grp), 0),
      'refund_value', coalesce((SELECT sum(refund_value) FROM grp), 0),
      'replacement_value', coalesce((SELECT sum(replacement_value) FROM grp), 0)
    ),
    'by_channel', coalesce((SELECT jsonb_agg(to_jsonb(g) ORDER BY g.grp, g.origin) FROM grp g), '[]'::jsonb)
  );
$fn$;

REVOKE ALL ON FUNCTION public.cx_action_metrics(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cx_action_metrics(date, date) TO authenticated;

CREATE OR REPLACE FUNCTION public.cx_actions_call(p_payload jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  s text;
  rid bigint;
BEGIN
  SELECT decrypted_secret INTO s FROM vault.decrypted_secrets WHERE name = 'eggsy_email_hook_secret';
  SELECT net.http_post(
    url := 'https://xodkbmtylftfmnxfnxxf.supabase.co/functions/v1/cx-actions',
    body := p_payload,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-eggsy-hook', s),
    timeout_milliseconds := 60000
  ) INTO rid;
  RETURN rid;
END
$fn$;

REVOKE ALL ON FUNCTION public.cx_actions_call(jsonb) FROM PUBLIC, anon, authenticated;

DO $fn$
BEGIN
  PERFORM cron.unschedule('cx-actions-tracking');
EXCEPTION WHEN OTHERS THEN
  NULL;
END
$fn$;

SELECT cron.schedule(
  'cx-actions-tracking',
  '20,50 * * * *',
  $$select public.cx_actions_call('{"action":"refresh_tracking"}'::jsonb)$$
);
