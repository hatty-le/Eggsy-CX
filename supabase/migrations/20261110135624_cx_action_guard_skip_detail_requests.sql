CREATE OR REPLACE FUNCTION public.cx_reply_requests_details(p_body text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- Hatty, 10 Nov 2026: replies that ask the customer for more information before an action
  -- (address, order number, photos, etc.) must not be blocked by the action guard.
  select coalesce(p_body, '') ~* (
    '(could|can|would) you (please )?(reply|send|let us know|share|provide|confirm|tell us|forward|attach|give us)'
    || '|please (reply|send|let us know|share|provide|confirm|tell us|forward|attach)'
    || '|(once|as soon as|when) (we (have|receive|get|hear)|you(''ve| have)? (sent|replied|confirmed|sent us))'
    || '|we(''ll| will) (need|just need)|could we (have|get)'
    || '|könnten sie|bitte (senden|schicken|teilen|antworten|geben sie)|sobald wir'
    || '|pourriez-vous|merci de nous (envoyer|indiquer)|d[eè]s que nous'
    || '|podr[ií]a(s)? (enviarnos|indicarnos|decirnos)|por favor,? (env[ií]enos|ind[ií]quenos)'
    || '|potrebbe (inviarci|indicarci)|per favore,? (inviaci|indicaci)'
  ) and coalesce(p_body, '') ~ '\?';
$function$;

CREATE OR REPLACE FUNCTION public.cx_promised_action_types(p_body text, p_flag boolean)
 RETURNS text[]
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  b text := coalesce(p_body, '');
  types text[] := '{}';
BEGIN
  -- Only block replies that say an action is done or will happen with nothing more needed from the customer.
  IF public.cx_reply_requests_details(b) THEN
    RETURN '{}';
  END IF;
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
