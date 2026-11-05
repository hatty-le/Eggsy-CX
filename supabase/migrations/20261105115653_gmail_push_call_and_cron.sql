CREATE OR REPLACE FUNCTION public.cx_gmail_call(p_payload jsonb DEFAULT '{}'::jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault, net
AS $$
DECLARE
  hook text;
  req_id bigint;
BEGIN
  SELECT decrypted_secret INTO hook
  FROM vault.decrypted_secrets
  WHERE name = 'eggsy_email_hook_secret'
  LIMIT 1;
  IF hook IS NULL THEN
    RAISE EXCEPTION 'eggsy_email_hook_secret is missing';
  END IF;
  SELECT net.http_post(
    url := 'https://xodkbmtylftfmnxfnxxf.supabase.co/functions/v1/gmail-push',
    body := coalesce(p_payload, '{}'::jsonb),
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-eggsy-hook', hook
    ),
    timeout_milliseconds := 120000
  ) INTO req_id;
  RETURN req_id;
END;
$$;

REVOKE ALL ON FUNCTION public.cx_gmail_call(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cx_gmail_call(jsonb) TO postgres, service_role;

SELECT cron.schedule(
  'gmail-hey-sync',
  '*/5 * * * *',
  $job$select public.cx_gmail_call('{"mode":"sync"}'::jsonb)$job$
);

SELECT cron.schedule(
  'gmail-hey-watch',
  '20 3 * * *',
  $job$select public.cx_gmail_call('{"mode":"watch"}'::jsonb)$job$
);