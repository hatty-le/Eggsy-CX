update public.cx_actions set details = details || '{"awaiting_details": true}'::jsonb where id='fcbb97bf-d408-43ae-8d3f-f94151085f9c';

CREATE OR REPLACE FUNCTION public.reply_queue_action_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
        AND (a.status IN ('created', 'done', 'expected', 'received')
             OR (a.status = 'pending' AND coalesce((a.details->>'awaiting_details')::boolean, false)))
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
        AND (a.status IN ('created', 'done', 'expected', 'received')
             OR (a.status = 'pending' AND coalesce((a.details->>'awaiting_details')::boolean, false)))
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
$function$;

CREATE OR REPLACE FUNCTION public.cx_draft_readiness()
 RETURNS TABLE(conversation_id uuid, notes integer, missing_actions text[], partial_history boolean, attachment_missing boolean, drafted_at timestamp with time zone)
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select d.conversation_id,
         coalesce((select count(*)::int from regexp_matches(d.body, '\[[^\]]*\]', 'g')), 0),
         coalesce((select array_agg(t) from unnest(public.cx_promised_action_types(d.body, false)) t
                   where not exists (select 1 from public.cx_actions a
                                     where a.conversation_id = d.conversation_id
                                       and (t = 'any' or a.type = t)
                                       and (a.status in ('created', 'done', 'expected', 'received')
                                            or (a.status = 'pending' and coalesce((a.details->>'awaiting_details')::boolean, false))))), '{}'),
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
