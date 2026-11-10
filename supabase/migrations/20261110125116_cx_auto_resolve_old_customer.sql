-- Auto-resolve conversations whose latest customer message is over 3 months old,
-- even if we never replied. Rule from Hatty, 10 Nov 2026. No customer reply is sent.

CREATE OR REPLACE FUNCTION public.cx_conversation_customer_at(p_conversation uuid)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT coalesce(
    (SELECT max(m.sent_at)
       FROM public.messages m
      WHERE m.conversation_id = p_conversation
        AND m.direction = 'inbound'),
    (SELECT c.last_message_at
       FROM public.conversations c
      WHERE c.id = p_conversation)
  );
$function$;

COMMENT ON FUNCTION public.cx_conversation_customer_at(uuid) IS
  'Latest inbound customer message time, falling back to conversations.last_message_at.';

CREATE OR REPLACE FUNCTION public.cx_auto_resolve_old_customer_one(
  p_conversation uuid,
  p_age interval DEFAULT interval '3 months'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  c record;
  age_at timestamptz;
  note text := 'Auto-resolved: no customer message for over 3 months (rule from Hatty, 10 Nov 2026)';
BEGIN
  IF p_conversation IS NULL THEN
    RETURN false;
  END IF;

  SELECT conv.id, conv.status, conv.order_number, conv.summary
    INTO c
    FROM public.conversations conv
   WHERE conv.id = p_conversation;

  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF c.status IN ('resolved', 'ignored') THEN
    RETURN false;
  END IF;
  IF coalesce(c.order_number, '') LIKE 'EGGSYTEST-%' THEN
    RETURN false;
  END IF;

  age_at := public.cx_conversation_customer_at(p_conversation);
  IF age_at IS NULL OR age_at >= now() - p_age THEN
    RETURN false;
  END IF;

  -- Do not interrupt an in-flight send; the daily sweep will catch it later.
  IF EXISTS (
    SELECT 1
      FROM public.reply_queue q
     WHERE q.conversation_id = p_conversation
       AND q.status = 'sending'
  ) THEN
    RETURN false;
  END IF;

  UPDATE public.reply_queue q
     SET status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = 'auto-resolved: no customer message for over 3 months',
         updated_at = now()
   WHERE q.conversation_id = p_conversation
     AND q.status = 'queued';

  PERFORM public.cx_supersede_drafts_on_send(p_conversation);

  UPDATE public.conversations
     SET status = 'resolved',
         summary = CASE
           WHEN coalesce(btrim(summary), '') = '' THEN note
           WHEN position(note IN summary) = 1 THEN summary
           ELSE note || E'\n\n' || summary
         END,
         updated_at = now()
   WHERE id = p_conversation
     AND status IS DISTINCT FROM 'resolved'
     AND status IS DISTINCT FROM 'ignored';

  INSERT INTO public.messages (conversation_id, direction, author, body, sent_at, external_id)
  VALUES (
    p_conversation,
    'note',
    'Eggsy',
    note,
    now(),
    'auto-resolved-old:' || p_conversation::text || ':' || to_char(timezone('Europe/London', now()), 'YYYYMMDD')
  )
  ON CONFLICT (conversation_id, external_id) DO NOTHING;

  RETURN true;
END;
$function$;

COMMENT ON FUNCTION public.cx_auto_resolve_old_customer_one(uuid, interval) IS
  'Resolves one conversation if the latest customer message is older than p_age. Cancels queued replies, supersedes drafts, and leaves a note. Does not send anything.';

CREATE OR REPLACE FUNCTION public.cx_auto_resolve_old_customer(
  p_age interval DEFAULT interval '3 months'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  n int := 0;
  r record;
BEGIN
  FOR r IN
    SELECT c.id
      FROM public.conversations c
     WHERE c.status NOT IN ('resolved', 'ignored')
       AND coalesce(c.order_number, '') NOT LIKE 'EGGSYTEST-%'
       AND public.cx_conversation_customer_at(c.id) < now() - p_age
  LOOP
    IF public.cx_auto_resolve_old_customer_one(r.id, p_age) THEN
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END;
$function$;

COMMENT ON FUNCTION public.cx_auto_resolve_old_customer(interval) IS
  'Sweep: auto-resolve every non-resolved conversation whose latest customer message is older than p_age (default 3 months).';

CREATE OR REPLACE FUNCTION public.cx_conversations_resolve_old_customer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  PERFORM public.cx_auto_resolve_old_customer_one(NEW.id);
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cx_messages_resolve_old_customer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  PERFORM public.cx_auto_resolve_old_customer_one(NEW.conversation_id);
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cx_drafts_resolve_old_customer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NOT NEW.superseded
     AND public.cx_conversation_customer_at(NEW.conversation_id) IS NOT NULL
     AND public.cx_conversation_customer_at(NEW.conversation_id) < now() - interval '3 months' THEN
    NEW.superseded := true;
    NEW.superseded_at := coalesce(NEW.superseded_at, now());
    PERFORM public.cx_auto_resolve_old_customer_one(NEW.conversation_id);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS conversations_resolve_old_customer ON public.conversations;
CREATE TRIGGER conversations_resolve_old_customer
  AFTER INSERT OR UPDATE OF status, last_message_at ON public.conversations
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM 'resolved' AND NEW.status IS DISTINCT FROM 'ignored')
  EXECUTE FUNCTION public.cx_conversations_resolve_old_customer();

DROP TRIGGER IF EXISTS messages_resolve_old_customer ON public.messages;
CREATE TRIGGER messages_resolve_old_customer
  AFTER INSERT ON public.messages
  FOR EACH ROW
  WHEN (NEW.direction = 'inbound')
  EXECUTE FUNCTION public.cx_messages_resolve_old_customer();

DROP TRIGGER IF EXISTS suggested_drafts_resolve_old_customer ON public.suggested_drafts;
CREATE TRIGGER suggested_drafts_resolve_old_customer
  BEFORE INSERT ON public.suggested_drafts
  FOR EACH ROW
  WHEN (NOT NEW.superseded)
  EXECUTE FUNCTION public.cx_drafts_resolve_old_customer();

REVOKE ALL ON FUNCTION public.cx_conversation_customer_at(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cx_auto_resolve_old_customer_one(uuid, interval) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cx_auto_resolve_old_customer(interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cx_conversation_customer_at(uuid) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.cx_auto_resolve_old_customer_one(uuid, interval) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.cx_auto_resolve_old_customer(interval) TO postgres, service_role;

-- Daily sweep at 06:13 UTC, alongside the existing 7-day waiting auto-resolve.
-- New job only; do not modify other cron jobs.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'cx-auto-resolve-old-customer';
SELECT cron.schedule(
  'cx-auto-resolve-old-customer',
  '13 6 * * *',
  'select public.cx_auto_resolve_old_customer()'
);

INSERT INTO public.cx_settings (key, value, updated_at, updated_by)
VALUES (
  'auto_resolve_old_customer',
  jsonb_build_object(
    'age', '3 months',
    'rule', 'Any conversation not already resolved whose latest customer message is more than 3 months old is marked resolved, with no reply sent.',
    'from', 'Hatty',
    'date', '2026-11-10'
  ),
  now(),
  'Eggsy'
)
ON CONFLICT (key) DO UPDATE
   SET value = excluded.value,
       updated_at = now(),
       updated_by = excluded.updated_by;

-- Drafting guidance: do not ask Hatty to check orders on tickets this old.
UPDATE public.kb_articles
   SET body = body || E'\n\n## Tickets over 3 months old\nIf the customer''s last message is more than 3 months old, do not draft a reply and do not leave a note asking Hatty to check the order. Those tickets are auto-resolved with no reply (rule from Hatty, 10 Nov 2026). If the customer writes again, the ticket comes back to Inbox as usual.\n',
       updated_at = now(),
       updated_by = 'Eggsy'
 WHERE id = '2397277e-0a55-4689-a74c-9a8408869b17'
   AND body NOT ILIKE '%Tickets over 3 months old%';

UPDATE public.kb_articles
   SET body = replace(
         body,
         E'- If tracking shows delivered, ask them to confirm and check around the address.\n',
         E'- If tracking shows delivered, ask them to confirm and check around the address.\n- If the customer''s last message is more than 3 months old, do not draft a reply and do not ask Hatty to check the Walmart order. Those tickets are auto-resolved with no reply. If the customer writes again, the ticket reopens.\n'
       ),
       updated_at = now(),
       updated_by = 'Eggsy'
 WHERE id = 'add36c68-99a7-4ee3-946b-5bbd4c94375d'
   AND body NOT ILIKE '%do not ask Hatty to check the Walmart order%';

-- Immediate backfill, including Amanda Storms.
SELECT public.cx_auto_resolve_old_customer();
