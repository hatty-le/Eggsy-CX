-- Read Dev Dashboard client credentials from Vault for cx-actions.
-- Does not create the secrets and does not store any secret value.
-- Names: shopify_client_id, shopify_client_secret.
CREATE OR REPLACE FUNCTION public.cx_shopify_client_credentials()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
  SELECT jsonb_build_object(
    'client_id', (
      SELECT decrypted_secret
      FROM vault.decrypted_secrets
      WHERE name = 'shopify_client_id'
      LIMIT 1
    ),
    'client_secret', (
      SELECT decrypted_secret
      FROM vault.decrypted_secrets
      WHERE name = 'shopify_client_secret'
      LIMIT 1
    )
  );
$fn$;

REVOKE ALL ON FUNCTION public.cx_shopify_client_credentials() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cx_shopify_client_credentials() TO service_role;
