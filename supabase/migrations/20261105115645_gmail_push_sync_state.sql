CREATE TABLE IF NOT EXISTS public.gmail_sync_state (
  id integer PRIMARY KEY CHECK (id = 1),
  history_id text,
  watch_expiration timestamptz,
  watch_topic text,
  last_synced_at timestamptz,
  last_result jsonb,
  last_error text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.gmail_sync_state ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.gmail_sync_state FROM anon, authenticated;
GRANT ALL ON TABLE public.gmail_sync_state TO service_role;

INSERT INTO public.gmail_sync_state (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vault.secrets WHERE name = 'eggsy_gmail_push_secret'
  ) THEN
    PERFORM vault.create_secret(
      encode(gen_random_bytes(32), 'hex'),
      'eggsy_gmail_push_secret',
      'Token for Gmail Pub/Sub push into Eggsy CX',
      NULL
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.cx_gmail_hook_ok(p_secret text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault
AS $$
DECLARE
  expected text;
BEGIN
  SELECT decrypted_secret INTO expected
  FROM vault.decrypted_secrets
  WHERE name = 'eggsy_gmail_push_secret'
  LIMIT 1;
  RETURN expected IS NOT NULL AND p_secret IS NOT NULL AND p_secret = expected;
END;
$$;

REVOKE ALL ON FUNCTION public.cx_gmail_hook_ok(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cx_gmail_hook_ok(text) TO service_role;