-- Hatty rule 10 Nov 2026: do not reply to Instagram or Facebook *public comments*
-- unless they @-mention one of our accounts/Pages AND ask a genuine question.
-- Messenger / Instagram DMs are unaffected.

CREATE OR REPLACE FUNCTION public.cx_is_meta_public_comment(p_origin public.cx_origin, p_external_id text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $fn$
  SELECT p_origin IN ('instagram'::public.cx_origin, 'facebook'::public.cx_origin)
     AND p_external_id IS NOT NULL
     AND (
       p_external_id LIKE 'igcomment:%'
       OR p_external_id LIKE 'fbcomment:%'
       OR p_external_id LIKE 'meta:igcomment:%'
       OR p_external_id LIKE 'meta:fbcomment:%'
     );
$fn$;

CREATE OR REPLACE FUNCTION public.cx_our_meta_handles()
RETURNS TABLE(handle text)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $fn$
  SELECT DISTINCT lower(btrim(x)) AS handle
  FROM (
    -- Official Page names and IG usernames (Meta Business, captured 6 Nov 2026)
    SELECT unnest(ARRAY[
      'luckyeggofficial',
      'luckyegggameplayuk',
      'luckyegg_gamesuk',
      'luckyegg.games.usa',
      'snortfunnyuk',
      'snortfunny.us',
      'grabthemicgame_uk',
      'grabthemicus',
      'grabthemic_france',
      'misheardmusic_uk',
      'misheardmusic.usa',
      'sorrywhatuk',
      'sorrywhatusa',
      'theguestlistclips',
      'wouldyoustillloveme.if',
      'lucky egg',
      'lucky egg official',
      'lucky egg usa',
      'lucky egg games uk',
      'lucky egg games uk b',
      'snort funny',
      'snort funny uk',
      'snort funny us',
      'grab the mic',
      'grab the mic uk',
      'grab the mic us',
      'grab the mic france',
      'misheard music',
      'misheard music uk',
      'misheard music usa',
      'sorry what',
      'sorry what uk',
      'sorry what game',
      'wonky doodles uk',
      'would you still love me if'
    ]) AS x
    UNION
    SELECT regexp_replace(c.shop, '\s+instagram$', '', 'i')
    FROM public.conversations c
    WHERE c.origin IN ('instagram'::public.cx_origin, 'facebook'::public.cx_origin)
      AND c.shop IS NOT NULL
      AND btrim(c.shop) <> ''
    UNION
    SELECT split_part(c.external_id, ':', 3)
    FROM public.conversations c
    WHERE c.origin = 'instagram'::public.cx_origin
      AND c.external_id LIKE 'meta:ig%:%'
      AND split_part(c.external_id, ':', 3) <> ''
  ) s
  WHERE btrim(x) <> ''
    AND length(btrim(x)) >= 5;
$fn$;

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
    pat := regexp_replace(h, '([.\\[\\](){}*+?^$|\\])', '\\\1', 'g');
    pat := regexp_replace(pat, '[[:space:]]+', '[[:space:]]+', 'g');
    IF p_body ~* ('(^|[^[:alnum:].])@' || pat || '([^[:alnum:]._]|$)') THEN
      RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.cx_text_asks_question(p_body text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $fn$
  SELECT p_body IS NOT NULL
     AND btrim(p_body) <> ''
     AND (
       p_body ~ '[?¿]'
       OR p_body ~* '(^|[[:space:]])(who|what|when|where|why|how|which|whose|whom|can you|could you|would you|will you|do you|did you|are you|is this|is it|is there|have you|has anyone|any idea|puedes |podr[ií]as |cu[aá]nto |d[oó]nde |c[oó]mo |comment |pourquoi |combien |o[uù] |warum |wieso |woher |perch[eé] |quando |dove )[[:space:]]'
       OR p_body ~* '^(who|what|when|where|why|how|which|can you|could you|do you|did you|are you|is there|have you|wo|was|wie|warum|comment|pourquoi|cu[aá]nto|d[oó]nde|c[oó]mo|quando|perch[eé]|dove)\b'
     );
$fn$;

CREATE OR REPLACE FUNCTION public.cx_inbound_is_mention_question(p_body text, p_body_en text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $fn$
  SELECT (public.cx_text_mentions_our_meta_account(p_body)
          OR public.cx_text_mentions_our_meta_account(p_body_en))
     AND (public.cx_text_asks_question(p_body)
          OR public.cx_text_asks_question(p_body_en));
$fn$;

CREATE OR REPLACE FUNCTION public.cx_meta_comment_should_ignore(
  p_origin public.cx_origin,
  p_external_id text,
  p_conversation_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO ''
AS $fn$
  SELECT public.cx_is_meta_public_comment(p_origin, p_external_id)
     AND NOT EXISTS (
       SELECT 1
       FROM public.messages m
       WHERE m.conversation_id = p_conversation_id
         AND m.direction = 'inbound'::public.cx_direction
         AND public.cx_inbound_is_mention_question(m.body, m.body_en)
     );
$fn$;

CREATE OR REPLACE FUNCTION public.cx_meta_comment_ignore_note(p_origin public.cx_origin)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $fn$
  SELECT CASE
    WHEN p_origin = 'instagram'::public.cx_origin
      THEN 'No reply needed: IG comment without @mention question (Hatty rule 10 Nov)'
    ELSE 'No reply needed: FB comment without @mention question (Hatty rule 10 Nov)'
  END;
$fn$;

CREATE OR REPLACE FUNCTION public.cx_conversations_meta_comment_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $fn$
BEGIN
  IF public.cx_meta_comment_should_ignore(NEW.origin, NEW.external_id, NEW.id)
     AND NEW.status IN ('open'::public.cx_status, 'awaiting_approval'::public.cx_status, 'awaiting_customer'::public.cx_status) THEN
    NEW.status := 'ignored'::public.cx_status;
    IF NEW.summary IS NULL
       OR btrim(NEW.summary) = ''
       OR NEW.summary NOT LIKE 'No reply needed: %comment without @mention question (Hatty rule 10 Nov)%' THEN
      NEW.summary := public.cx_meta_comment_ignore_note(NEW.origin);
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS conversations_meta_comment_guard ON public.conversations;
CREATE TRIGGER conversations_meta_comment_guard
  BEFORE INSERT OR UPDATE ON public.conversations
  FOR EACH ROW
  EXECUTE FUNCTION public.cx_conversations_meta_comment_guard();

CREATE OR REPLACE FUNCTION public.cx_messages_meta_comment_rule()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  conv record;
BEGIN
  IF NEW.direction IS DISTINCT FROM 'inbound'::public.cx_direction THEN
    RETURN NEW;
  END IF;
  SELECT c.id, c.origin, c.external_id, c.status
    INTO conv
    FROM public.conversations c
   WHERE c.id = NEW.conversation_id;
  IF NOT FOUND OR NOT public.cx_is_meta_public_comment(conv.origin, conv.external_id) THEN
    RETURN NEW;
  END IF;

  IF public.cx_meta_comment_should_ignore(conv.origin, conv.external_id, conv.id) THEN
    UPDATE public.conversations c
       SET status = 'ignored'::public.cx_status,
           summary = public.cx_meta_comment_ignore_note(c.origin),
           updated_at = now()
     WHERE c.id = conv.id
       AND c.status IN ('open'::public.cx_status, 'awaiting_approval'::public.cx_status, 'awaiting_customer'::public.cx_status);
    UPDATE public.suggested_drafts d
       SET superseded = true, superseded_at = now()
     WHERE d.conversation_id = conv.id
       AND NOT d.superseded;
    UPDATE public.reply_queue q
       SET status = 'cancelled'::public.cx_send_status,
           cancelled_at = now(),
           cancelled_by = 'eggsy (Hatty: IG/FB comments only answered if they @ us with a question)',
           updated_at = now()
     WHERE q.conversation_id = conv.id
       AND q.status IN ('queued'::public.cx_send_status, 'sending'::public.cx_send_status);
  ELSIF conv.status = 'ignored'::public.cx_status THEN
    UPDATE public.conversations c
       SET status = 'open'::public.cx_status,
           summary = 'Needs reply: public comment @-mentions us with a question (Hatty rule 10 Nov)',
           updated_at = now()
     WHERE c.id = conv.id
       AND c.status = 'ignored'::public.cx_status;
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS messages_meta_comment_rule ON public.messages;
CREATE TRIGGER messages_meta_comment_rule
  AFTER INSERT OR UPDATE OF body, body_en, direction ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION public.cx_messages_meta_comment_rule();

CREATE OR REPLACE FUNCTION public.cx_suggested_drafts_meta_comment_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $fn$
DECLARE
  conv record;
BEGIN
  IF NEW.superseded THEN
    RETURN NEW;
  END IF;
  SELECT c.origin, c.external_id INTO conv
    FROM public.conversations c
   WHERE c.id = NEW.conversation_id;
  IF FOUND AND public.cx_meta_comment_should_ignore(conv.origin, conv.external_id, NEW.conversation_id) THEN
    NEW.superseded := true;
    NEW.superseded_at := coalesce(NEW.superseded_at, now());
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS suggested_drafts_meta_comment_guard ON public.suggested_drafts;
CREATE TRIGGER suggested_drafts_meta_comment_guard
  BEFORE INSERT OR UPDATE ON public.suggested_drafts
  FOR EACH ROW
  EXECUTE FUNCTION public.cx_suggested_drafts_meta_comment_guard();

CREATE OR REPLACE FUNCTION public.cx_reply_queue_meta_comment_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $fn$
DECLARE
  conv record;
BEGIN
  IF NEW.status IS NULL OR NEW.status NOT IN ('queued'::public.cx_send_status, 'sending'::public.cx_send_status, 'sent'::public.cx_send_status) THEN
    RETURN NEW;
  END IF;
  SELECT c.origin, c.external_id INTO conv
    FROM public.conversations c
   WHERE c.id = NEW.conversation_id;
  IF FOUND AND public.cx_meta_comment_should_ignore(conv.origin, conv.external_id, NEW.conversation_id) THEN
    RAISE EXCEPTION 'Instagram and Facebook comments are only answered when they @-mention one of our accounts and ask a question (Hatty rule 10 Nov 2026).'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS reply_queue_zy_meta_comment_guard ON public.reply_queue;
CREATE TRIGGER reply_queue_zy_meta_comment_guard
  BEFORE INSERT OR UPDATE ON public.reply_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.cx_reply_queue_meta_comment_guard();

-- Defence in depth: Ready auto-send must not queue a non-qualifying comment reply.
CREATE OR REPLACE FUNCTION public.cx_queue_ready_draft(p_conversation uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c record;
  r record;
  last_in text;
  last_in_at timestamptz;
  already text;
  amazon_problem text;
  q_latest record;
  hold text;
  result text;
  depth int := coalesce(nullif(current_setting('eggsy.queue_ready_depth', true), ''), '0')::int;
begin
  if depth > 0 then
    return 'in_progress';
  end if;
  perform set_config('eggsy.queue_ready_depth', '1', true);

  begin
    if coalesce((select value from public.cx_settings where key = 'auto_send_ready'), 'false'::jsonb) <> 'true'::jsonb then
      result := 'disabled';
    else
      select conv.id, conv.origin, conv.shop, conv.status, conv.flag, conv.topic, conv.subject,
             conv.order_number, conv.kind, conv.customer_handle, conv.external_id, st.bucket,
             st.last_customer_at, st.last_reply_at
        into c
        from public.conversations conv
        join public.cx_conversation_state st on st.conversation_id = conv.id
       where conv.id = p_conversation;
      if not found then
        result := 'not_found';
      elsif c.bucket is distinct from 'inbox' then
        result := 'not_inbox';
      elsif c.status = 'ignored' then
        result := 'junk_ignored';
      elsif public.cx_meta_comment_should_ignore(c.origin, c.external_id, c.id) then
        result := 'meta_comment_no_reply';
      elsif c.flag is not null
         and c.flag !~* '^Not sending: a teammate or chatbot already replied' then
        result := 'flagged';
      elsif coalesce(c.order_number, '') like 'EGGSYTEST-%' then
        result := 'test_ticket';
      elsif coalesce(c.topic, '') ~* '(affiliate|spam|newsletter|sourcing)' then
        result := 'junk_topic';
      elsif exists (
        select 1 from public.reply_queue q
         where q.conversation_id = p_conversation
           and q.status in ('queued', 'sending')
      ) then
        result := 'already_queued';
      else
        select x.conversation_id, x.notes, x.missing_actions, x.partial_history,
               x.attachment_missing, x.drafted_at, d0.body, d0.id as draft_id
          into r
          from public.cx_draft_readiness() x
          join public.suggested_drafts d0
            on d0.conversation_id = x.conversation_id and not d0.superseded
         where x.conversation_id = p_conversation
         order by d0.drafted_at desc
         limit 1;
        if not found or r.notes > 0 or cardinality(r.missing_actions) > 0
           or r.partial_history or r.attachment_missing or coalesce(btrim(r.body), '') = '' then
          result := 'not_ready';
        else
          select m.body, m.sent_at into last_in, last_in_at
            from public.messages m
           where m.conversation_id = p_conversation
             and m.direction = 'inbound'
           order by m.sent_at desc
           limit 1;

          if last_in_at is not null then
            select left(m.author || ': ' || m.body, 160) into already
              from public.messages m
             where m.conversation_id = p_conversation
               and m.sent_at >= last_in_at
               and (
                 (m.direction = 'outbound' and not public.cx_is_internal_outbound(m.author, m.body))
                 or (
                   m.direction = 'note'
                   and (
                     m.author ~* 'chatbot auto-reply'
                     or m.author ~* 'customer service[0-9]'
                     or (
                       m.author ~* 'lucky egg'
                       and m.author !~* 'automatic notice'
                       and m.body !~* '(eggsy log:|imported from|started the chat|chat ended|has been assigned|chat was assigned|timed out|order delivered|signed for|we''ve shipped)'
                     )
                   )
                 )
               )
             order by m.sent_at
             limit 1;
          end if;

          select q.status, q.cancelled_by, q.body, q.send_error
            into q_latest
            from public.reply_queue q
           where q.conversation_id = p_conversation
           order by q.queued_at desc nulls last
           limit 1;

          if already is not null then
            hold := 'already_replied';
            perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
            result := hold;
          elsif found
             and q_latest.status = 'cancelled'
             and (
               coalesce(q_latest.cancelled_by, '') ~* '(already replied|team already|teammate|chatbot already)'
               or q_latest.body is not distinct from r.body
             ) then
            hold := case
              when coalesce(q_latest.cancelled_by, '') ~* '(already replied|team already|teammate|chatbot already)'
                then 'cancelled_already_replied'
              else 'cancelled_same_draft'
            end;
            perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
            result := hold;
          elsif found and q_latest.status = 'failed' and q_latest.body is not distinct from r.body then
            result := 'previous_send_failed';
          elsif public.cx_is_us_eu_ticket(c.origin, c.shop)
             and (
               public.cx_is_refund_ticket(c.topic, c.subject, r.body, last_in)
               or exists (
                 select 1 from public.cx_actions a
                  where a.conversation_id = p_conversation and a.type = 'refund'
               )
             ) then
            hold := 'us_eu_refund_escalate';
            perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
            result := hold;
          else
            if c.origin::text like 'amazon%' then
              amazon_problem := public.cx_amazon_reply_problem(r.body);
            end if;
            if amazon_problem is not null then
              hold := 'amazon_not_plain:' || amazon_problem;
              perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
              result := hold;
            elsif c.origin = 'wix_mmc_form'
               and not exists (
                 select 1 from public.email_send_channels e
                  where e.origin = c.origin and e.enabled
               ) then
              hold := 'no_send_path';
              perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
              result := hold;
            else
              begin
                insert into public.reply_queue (conversation_id, body, queued_by, requires_action, auto_sent)
                values (p_conversation, r.body, 'eggsy-auto', false, true);
                result := 'queued';
              exception when others then
                hold := 'guard_blocked:' || sqlerrm;
                perform public.cx_apply_unsent_ready_hold(p_conversation, hold);
                result := hold;
              end;
            end if;
          end if;
        end if;
      end if;
    end if;
  exception when others then
    perform set_config('eggsy.queue_ready_depth', '0', true);
    raise;
  end;

  perform set_config('eggsy.queue_ready_depth', '0', true);
  return result;
end
$function$;

-- Knowledge base
INSERT INTO public.kb_articles (
  slug, title, category, body, applies_to, language,
  source_name, source_updated_at, status, notes, updated_by, published_at
) VALUES (
  'meta-comment-reply-rule',
  'Instagram and Facebook comments: only reply when they @ us with a question',
  'Channel rules',
  $kb$## Rule (Hatty, 10 Nov 2026)

There is no need to reply to Instagram or Facebook **public comments** unless they **@-mention one of our accounts or Pages** and **specifically ask a question**.

Both conditions are required:

1. The comment @-mentions one of Lucky Egg's Instagram accounts or Facebook Pages (for example @luckyeggofficial, @snortfunnyuk, @Lucky Egg, @Snort Funny UK, @Grab The Mic UK). A tag of a friend or another brand does not count.
2. The comment asks a genuine question (a question mark, or a clear question such as "where can I buy this?" or "have you shipped my order?"). Jokes, praise, "we need this", friend tags, reactions and "link please" without an @mention of us do not get a reply.

If either condition is missing, mark the ticket **ignored**. Do not draft, queue, approve or send a reply.

## What this does not apply to

- Instagram DMs and Facebook Messenger private messages still flow normally and can be drafted and replied to as usual.
- A public comment that @-mentions us and asks a question is treated like any other ticket that needs a reply.

## Do not post privately in public

Don't post order details or addresses in public comments.
$kb$,
  ARRAY['instagram'::public.cx_origin, 'facebook'::public.cx_origin],
  'en',
  'Hatty Innes, 10 Nov 2026',
  '2026-11-10',
  'published',
  'Standing rule. DB guard: cx_meta_comment_should_ignore, conversations_meta_comment_guard, messages_meta_comment_rule, suggested_drafts_meta_comment_guard, reply_queue_zy_meta_comment_guard.',
  'Eggsy',
  now()
)
ON CONFLICT (slug) DO UPDATE
  SET title = excluded.title,
      category = excluded.category,
      body = excluded.body,
      applies_to = excluded.applies_to,
      source_name = excluded.source_name,
      source_updated_at = excluded.source_updated_at,
      status = excluded.status,
      notes = excluded.notes,
      updated_by = excluded.updated_by,
      published_at = coalesce(public.kb_articles.published_at, now()),
      updated_at = now();

UPDATE public.kb_articles
   SET body = body || $extra$

## Public comments (Hatty, 10 Nov 2026)
There is no need to reply to Instagram or Facebook public comments unless they @-mention one of our accounts or Pages **and** specifically ask a question. Both are required. Jokes, praise, friend tags and comments that only talk to other people should be marked ignored. Instagram DMs and Facebook Messenger are not affected. See the article "Instagram and Facebook comments: only reply when they @ us with a question".
$extra$,
       updated_at = now(),
       updated_by = 'Eggsy',
       source_updated_at = '2026-11-10'
 WHERE slug = 'channel-rules'
   AND body NOT LIKE '%Public comments (Hatty, 10 Nov 2026)%';
