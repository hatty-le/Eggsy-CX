-- Who resolved each conversation: a bot, a bot then a person, a person using an AI draft, or a person alone.
-- Powers the "Bots vs people" overview on the Metrics page.

-- A reply written by an automated system (marketplace chatbots, auto-replies, greetings, notices).
create or replace function public.cx_is_bot_author(a text) returns boolean language sql immutable set search_path = '' as $$
  select coalesce(a, '') ~* '(chatbot|auto-|auto |autom|\mAI\M|greeting|notification|notice)' $$;

-- One row per conversation that ended up resolved, classified by who replied.
create or replace view public.cx_metric_resolution with (security_invoker = true) as
with c as (
  select c.id, c.origin::text as origin, public.cx_channel_group(c.origin::text) as grp,
         coalesce(c.status_changed_at, c.last_message_at, c.created_at) as resolved_at
  from public.conversations c
  where c.status::text = 'resolved'
    and coalesce(c.order_number, '') not like 'EGGSYTEST-%'
), r as (
  select m.conversation_id,
         count(*) filter (where public.cx_is_bot_author(m.author)
                            and m.direction::text in ('outbound', 'note')
                            and coalesce(m.author, '') not in ('Eggsy', 'TikTok system', 'Amazon Seller Central')) as bot_replies,
         count(*) filter (where m.direction::text = 'outbound'
                            and not public.cx_is_bot_author(m.author)
                            and coalesce(m.body, '') !~* '-{5,} ?Forwarded message') as human_replies
  from public.messages m
  group by 1
), ai as (
  -- A person sent the reply from Eggsy CX and an AI draft existed for the conversation before they queued it.
  select distinct q.conversation_id
  from public.reply_queue q
  where q.status = 'sent'
    and exists (select 1 from public.suggested_drafts d
                where d.conversation_id = q.conversation_id and d.drafted_at <= q.queued_at)
)
select c.id as conversation_id, c.origin, c.grp,
       (c.resolved_at at time zone 'Europe/London')::date as uk_day,
       coalesce(r.bot_replies, 0) as bot_replies, coalesce(r.human_replies, 0) as human_replies,
       case
         when coalesce(r.bot_replies, 0) > 0 and coalesce(r.human_replies, 0) = 0 then 'bot'
         when coalesce(r.bot_replies, 0) > 0 then 'bot_then_human'
         when ai.conversation_id is not null then 'ai_drafted'
         when coalesce(r.human_replies, 0) > 0 then 'human'
         else 'no_reply'
       end as resolved_by
from c
left join r on r.conversation_id = c.id
left join ai on ai.conversation_id = c.id;

create or replace function public.cx_resolution_split(p_from date, p_to date)
returns jsonb language sql stable security invoker set search_path = '' as $$
  with x as (select * from public.cx_metric_resolution where uk_day between p_from and p_to),
  g as (
    select grp, null::text as origin, true as is_total, count(*) as resolved,
           count(*) filter (where resolved_by = 'bot') as bot,
           count(*) filter (where resolved_by = 'bot_then_human') as bot_then_human,
           count(*) filter (where resolved_by = 'ai_drafted') as ai_drafted,
           count(*) filter (where resolved_by = 'human') as human,
           count(*) filter (where resolved_by = 'no_reply') as no_reply
    from x group by grp
    union all
    select grp, origin, false, count(*),
           count(*) filter (where resolved_by = 'bot'),
           count(*) filter (where resolved_by = 'bot_then_human'),
           count(*) filter (where resolved_by = 'ai_drafted'),
           count(*) filter (where resolved_by = 'human'),
           count(*) filter (where resolved_by = 'no_reply')
    from x group by grp, origin
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(g)) from g), '[]'::jsonb),
    'total', (select jsonb_build_object(
                'resolved', count(*),
                'bot', count(*) filter (where resolved_by = 'bot'),
                'bot_then_human', count(*) filter (where resolved_by = 'bot_then_human'),
                'ai_drafted', count(*) filter (where resolved_by = 'ai_drafted'),
                'human', count(*) filter (where resolved_by = 'human'),
                'no_reply', count(*) filter (where resolved_by = 'no_reply')) from x))
$$;

grant select on public.cx_metric_resolution to authenticated;
grant execute on function public.cx_resolution_split(date, date) to authenticated;
grant execute on function public.cx_is_bot_author(text) to authenticated;
