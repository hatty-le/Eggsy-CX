-- Eggsy CX metrics: first response times, volumes, unanswered. Live views over stored messages.
create or replace function public.cx_channel_group(o text) returns text language sql immutable set search_path = '' as $$
  select case when o = 'email_hey' then 'email'
              when o in ('shopify_form','wix_mmc_form') then 'forms'
              when o like 'amazon%' then 'amazon'
              when o like 'tiktok%' then 'tiktok'
              when o = 'walmart' then 'walmart'
              when o in ('facebook','instagram') then 'meta'
              else 'other' end $$;

-- Every stored message, classified. Same rules as the inbox: ignored conversations (creator/affiliate chats,
-- spam, vendor pitches) and test rows are left out; automated / AI / chatbot / internal outbound is not a reply.
create or replace view public.cx_metric_messages with (security_invoker = true) as
select m.id, m.conversation_id, c.origin::text as origin, public.cx_channel_group(c.origin::text) as grp,
       m.direction::text as direction, m.author, m.sent_at,
       (m.body like '[Summary by Eggsy%') as approx_time,
       case
         when m.direction::text = 'inbound' and coalesce(m.author,'') <> 'Amazon Customer Service' then 'customer'
         when m.direction::text = 'outbound' and not (
              coalesce(m.author,'') in ('Marty Pardoe','hey@luckyegg.co')
           or coalesce(m.body,'') ~* '-{5,} ?Forwarded message'
           or coalesce(m.author,'') ~ '\mAI\M'
           or coalesce(m.author,'') ~* '(auto-|auto |autom|chatbot|greeting|notification)'
           or (c.origin::text like 'tiktok%' and coalesce(m.author,'') = 'Lucky Egg')
         ) then 'reply'
         when m.direction::text = 'outbound' then 'automated_or_internal'
         else 'other'
       end as kind
from public.messages m
join public.conversations c on c.id = m.conversation_id
where c.status::text <> 'ignored'
  and coalesce(c.order_number,'') not like 'EGGSYTEST-%'
  and m.sent_at is not null;

-- One row per customer conversation: first customer message -> first real reply after it (clock hours).
create or replace view public.cx_metric_first_response with (security_invoker = true) as
with f as (
  select conversation_id, origin, grp, min(sent_at) as first_customer_at,
         bool_or(approx_time) as any_approx
  from public.cx_metric_messages where kind = 'customer' group by 1,2,3
), r as (
  select f.*,
         (select min(x.sent_at) from public.cx_metric_messages x
           where x.conversation_id = f.conversation_id and x.kind = 'reply' and x.sent_at >= f.first_customer_at) as first_reply_at,
         (select max(x.sent_at) from public.cx_metric_messages x where x.conversation_id = f.conversation_id and x.kind = 'customer') as last_customer_at,
         (select max(x.sent_at) from public.cx_metric_messages x where x.conversation_id = f.conversation_id and x.kind = 'reply') as last_reply_at
  from f
)
select r.conversation_id, r.origin, r.grp, c.customer_name, c.status::text as status,
       r.first_customer_at, r.first_reply_at,
       round((extract(epoch from (r.first_reply_at - r.first_customer_at)) / 3600.0)::numeric, 2) as first_response_hours,
       (r.first_customer_at at time zone 'Europe/London')::date as uk_day,
       date_trunc('week', r.first_customer_at at time zone 'Europe/London')::date as uk_week,
       r.last_customer_at, r.last_reply_at,
       (c.status::text in ('open','awaiting_approval') and (r.last_reply_at is null or r.last_customer_at > r.last_reply_at)) as unanswered,
       r.any_approx as approx_time
from r join public.conversations c on c.id = r.conversation_id;

-- All numbers for the Metrics page for a UK date range (inclusive).
create or replace function public.cx_metrics(p_from date, p_to date, p_baseline_hours numeric default 11)
returns jsonb language sql stable security invoker set search_path = '' as $$
with fr as (
  select * from public.cx_metric_first_response where uk_day between p_from and p_to
), msgs as (
  select *, (sent_at at time zone 'Europe/London')::date as uk_day,
         date_trunc('week', sent_at at time zone 'Europe/London')::date as uk_week
  from public.cx_metric_messages where kind in ('customer','reply')
    and (sent_at at time zone 'Europe/London')::date between p_from and p_to
), days as (select d::date as uk_day from generate_series(p_from, p_to, interval '1 day') d),
summary as (
  select count(*) as conversations, count(first_reply_at) as answered,
         round(avg(first_response_hours), 1) as avg_h,
         round((percentile_cont(0.5) within group (order by first_response_hours))::numeric, 1) as median_h,
         round((percentile_cont(0.9) within group (order by first_response_hours))::numeric, 1) as p90_h,
         count(*) filter (where first_response_hours <= 1) as within_1h,
         count(*) filter (where first_response_hours <= 24) as within_24h
  from fr
), byday as (
  select d.uk_day,
    (select count(*) from fr where fr.uk_day = d.uk_day) as new_conversations,
    (select count(*) from msgs where msgs.uk_day = d.uk_day and kind = 'customer') as customer_messages,
    (select count(*) from msgs where msgs.uk_day = d.uk_day and kind = 'reply') as replies_sent,
    (select round(avg(first_response_hours),1) from fr where fr.uk_day = d.uk_day) as avg_h,
    (select round((percentile_cont(0.5) within group (order by first_response_hours))::numeric,1) from fr where fr.uk_day = d.uk_day) as median_h
  from days d
), weeks as (select distinct date_trunc('week', uk_day)::date as uk_week from days),
byweek as (
  select w.uk_week,
    (select count(*) from fr where fr.uk_week = w.uk_week) as new_conversations,
    (select count(*) from msgs where msgs.uk_week = w.uk_week and kind = 'customer') as customer_messages,
    (select count(*) from msgs where msgs.uk_week = w.uk_week and kind = 'reply') as replies_sent,
    (select round(avg(first_response_hours),1) from fr where fr.uk_week = w.uk_week) as avg_h,
    (select round((percentile_cont(0.5) within group (order by first_response_hours))::numeric,1) from fr where fr.uk_week = w.uk_week) as median_h
  from weeks w
), bych as (
  select grp, origin, count(*) as conversations, count(first_reply_at) as answered,
         round(avg(first_response_hours),1) as avg_h,
         round((percentile_cont(0.5) within group (order by first_response_hours))::numeric,1) as median_h,
         grouping(origin) as is_total
  from fr group by grouping sets ((grp), (grp, origin))
), vol_ch as (
  select grp, origin, count(*) filter (where kind='customer') as customer_messages, count(*) filter (where kind='reply') as replies_sent
  from msgs group by grouping sets ((grp),(grp,origin))
), un as (
  select conversation_id, origin, grp, customer_name, status, last_customer_at,
         round((extract(epoch from (now() - last_customer_at))/3600.0)::numeric, 1) as waiting_h
  from public.cx_metric_first_response where unanswered
)
select jsonb_build_object(
  'from', p_from, 'to', p_to, 'baseline_hours', p_baseline_hours, 'generated_at', now(),
  'summary', (select to_jsonb(s) || jsonb_build_object('vs_baseline_pct',
                 case when s.avg_h is null then null else round((p_baseline_hours - s.avg_h) / p_baseline_hours * 100) end) from summary s),
  'by_day', coalesce((select jsonb_agg(b order by uk_day) from byday b), '[]'),
  'by_week', coalesce((select jsonb_agg(b order by uk_week) from byweek b), '[]'),
  'by_channel', coalesce((select jsonb_agg(to_jsonb(b) || coalesce((select jsonb_build_object('customer_messages', v.customer_messages, 'replies_sent', v.replies_sent)
                     from vol_ch v where v.grp = b.grp and v.origin is not distinct from b.origin), '{}')) from bych b), '[]'),
  'unanswered', jsonb_build_object('total', (select count(*) from un), 'over_24h', (select count(*) from un where waiting_h > 24),
                  'items', coalesce((select jsonb_agg(u order by last_customer_at) from un u), '[]')),
  'coverage', coalesce((select jsonb_agg(c) from (
                  select origin, grp, min(sent_at) as earliest, max(sent_at) as latest, count(*) as messages,
                         count(*) filter (where approx_time) as approx_time_messages
                  from public.cx_metric_messages where kind in ('customer','reply') group by 1,2 order by 2,1) c), '[]')
) $$;

revoke all on function public.cx_metrics(date,date,numeric) from public, anon;
grant execute on function public.cx_metrics(date,date,numeric) to authenticated;
revoke all on public.cx_metric_messages, public.cx_metric_first_response from anon;
grant select on public.cx_metric_messages, public.cx_metric_first_response to authenticated;
