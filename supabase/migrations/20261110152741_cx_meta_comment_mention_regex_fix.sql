CREATE OR REPLACE FUNCTION public.cx_text_mentions_our_meta_account(p_body text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path TO ''
AS $fn$
DECLARE
  h text;
  pat text;
BEGIN
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RETURN false;
  END IF;
  FOR h IN
    SELECT h2.handle FROM public.cx_our_meta_handles() AS h2
    ORDER BY length(h2.handle) DESC
  LOOP
    -- Handles only contain letters, digits, underscores, dots and spaces.
    pat := replace(h, '.', '\.');
    pat := regexp_replace(pat, '[[:space:]]+', '[[:space:]]+', 'g');
    IF p_body ~* ('(^|[^[:alnum:].])@' || pat || '([^[:alnum:]._]|$)') THEN
      RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END;
$fn$;
