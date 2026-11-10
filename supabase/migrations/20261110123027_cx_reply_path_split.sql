-- Extend cx_reply_route_split so the Metrics overview can show replies by send path:
-- Hatty / Mich / Kim on Eggsy, auto-sent on Eggsy, or sent on the native platform.
-- Auto means eggsy-auto / auto-approved Ready (a person did not queue it), not reply_queue.auto_sent,
-- which is also true for some staff-queued emails. Platform chatbot replies are included in native,
-- with native_chatbot as a sub-count. Duplicate sent_log/queue rows for the same message are not counted twice.
-- Applied on production as 20261110123027. Behaviour matches the live function; do not change it here.

CREATE OR REPLACE FUNCTION public.cx_reply_route_split(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with rq as (
    select * from public.reply_queue where status = 'sent'
  ), msgs as (
    select m.id, m.conversation_id, m.author, m.sent_at, m.external_id,
           c.origin::text as origin, public.cx_channel_group(c.origin::text) as grp,
           public.cx_is_bot_author(m.author) as is_bot,
           q.id as rq_id, q.queued_by, q.send_route, s.approved_by, s.route as sl_route,
           (q.id is not null or s.id is not null
            or coalesce(m.author, '') ~* 'queued by |sent by Eggsy') as via_eggsy
    from public.messages m
    join public.conversations c on c.id = m.conversation_id
    left join rq q on q.message_id = m.id
    left join lateral (
      select sl.* from public.sent_log sl
      where sl.message_id = m.id
         or (sl.external_id is not null and m.external_id is not null and sl.external_id = m.external_id)
         or (q.id is not null and sl.reply_queue_id = q.id)
      order by (sl.message_id is not null) desc, sl.sent_at
      limit 1
    ) s on true
    where m.direction::text = 'outbound'
      and coalesce(m.body, '') !~* '-{5,} ?Forwarded message'
      and coalesce(m.author, '') not in ('Marty Pardoe', 'hey@luckyegg.co')
      and coalesce(c.order_number, '') not like 'EGGSYTEST-%'
      and (m.sent_at at time zone 'Europe/London')::date between p_from and p_to
  ), orphans as (
    select r.id, r.conversation_id, null::text as author, r.sent_at, r.sent_external_id as external_id,
           r.origin::text as origin, public.cx_channel_group(r.origin::text) as grp, false as is_bot,
           r.id as rq_id, r.queued_by, r.send_route, s.approved_by, s.route as sl_route, true as via_eggsy
    from rq r
    join public.conversations c on c.id = r.conversation_id
    left join public.sent_log s on s.reply_queue_id = r.id
    where r.message_id is null
      and coalesce(c.order_number, '') not like 'EGGSYTEST-%'
      and (r.sent_at at time zone 'Europe/London')::date between p_from and p_to
      and not exists (
        select 1 from msgs m
        where m.rq_id = r.id
           or (m.conversation_id = r.conversation_id and r.sent_at is not null and m.sent_at is not null
               and abs(extract(epoch from (m.sent_at - r.sent_at))) <= 180)
      )
  ), raw as (
    select * from msgs union all select * from orphans
  ), x as (
    select origin, grp, is_bot, via_eggsy,
           lower(coalesce(
             case when queued_by ~* '@luckyegg\.co$' then queued_by end,
             case when approved_by ~* '@luckyegg\.co$' then approved_by end,
             substring(author from 'queued by ([^)]+)'),
             queued_by, approved_by, ''
           )) as actor,
           case
             when not via_eggsy then 'native'
             when lower(coalesce(
               case when queued_by ~* '@luckyegg\.co$' then queued_by end,
               case when approved_by ~* '@luckyegg\.co$' then approved_by end,
               substring(author from 'queued by ([^)]+)'),
               queued_by, approved_by, ''
             )) like 'hatty@%' then 'hatty'
             when lower(coalesce(
               case when queued_by ~* '@luckyegg\.co$' then queued_by end,
               case when approved_by ~* '@luckyegg\.co$' then approved_by end,
               substring(author from 'queued by ([^)]+)'),
               queued_by, approved_by, ''
             )) like 'mich@%' then 'mich'
             when lower(coalesce(
               case when queued_by ~* '@luckyegg\.co$' then queued_by end,
               case when approved_by ~* '@luckyegg\.co$' then approved_by end,
               substring(author from 'queued by ([^)]+)'),
               queued_by, approved_by, ''
             )) like 'kim@%' then 'kim'
             when coalesce(queued_by, '') ~* 'eggsy-auto'
               or coalesce(approved_by, '') ~* 'eggsy-auto'
               or coalesce(send_route, '') ~* 'auto-approved ready'
               or coalesce(sl_route, '') ~* 'auto-approved ready'
               or coalesce(author, '') ~* 'queued by eggsy-auto'
               then 'auto'
             else 'other'
           end as path
    from raw
  ), g as (
    select grp, null::text as origin, true as is_total, count(*) as replies,
           count(*) filter (where via_eggsy) as eggsy,
           count(*) filter (where path = 'auto') as auto,
           count(*) filter (where path = 'native') as native,
           count(*) filter (where path = 'hatty') as hatty,
           count(*) filter (where path = 'mich') as mich,
           count(*) filter (where path = 'kim') as kim,
           count(*) filter (where path = 'other') as other,
           count(*) filter (where path = 'native' and is_bot) as native_chatbot
    from x group by grp
    union all
    select grp, origin, false, count(*),
           count(*) filter (where via_eggsy),
           count(*) filter (where path = 'auto'),
           count(*) filter (where path = 'native'),
           count(*) filter (where path = 'hatty'),
           count(*) filter (where path = 'mich'),
           count(*) filter (where path = 'kim'),
           count(*) filter (where path = 'other'),
           count(*) filter (where path = 'native' and is_bot)
    from x group by grp, origin
  ), tot as (
    select count(*) as replies,
           count(*) filter (where via_eggsy) as eggsy,
           count(*) filter (where path = 'auto') as auto,
           count(*) filter (where path = 'native') as native,
           count(*) filter (where path = 'hatty') as hatty,
           count(*) filter (where path = 'mich') as mich,
           count(*) filter (where path = 'kim') as kim,
           count(*) filter (where path = 'other') as other,
           count(*) filter (where path = 'native' and is_bot) as native_chatbot
    from x
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(g)) from g), '[]'::jsonb),
    'total', (select to_jsonb(t) from tot t)
  )
$function$;
