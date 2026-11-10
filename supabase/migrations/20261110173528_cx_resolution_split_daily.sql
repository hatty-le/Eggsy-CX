-- One UK day per row for the bots-vs-people chart.
-- Same view and categories as cx_resolution_split. That function is not changed.
-- uk_day is the ticket's resolved date in Europe/London.

create or replace function public.cx_resolution_split_daily(p_from date, p_to date)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $function$
  with days as (
    select gs::date as uk_day
    from generate_series(p_from, p_to, interval '1 day') as gs
  ), g as (
    select uk_day,
           count(*) filter (where resolved_by = 'human') as human,
           count(*) filter (where resolved_by = 'bot_then_human') as bot_then_human,
           count(*) filter (where resolved_by = 'ai_drafted') as ai_drafted,
           count(*) filter (where resolved_by = 'ai_auto') as ai_auto,
           count(*) filter (where resolved_by = 'bot') as bot,
           count(*) filter (where resolved_by = 'no_reply') as no_reply
    from public.cx_metric_resolution
    where uk_day between p_from and p_to
    group by uk_day
  )
  select jsonb_build_object(
    'days', coalesce((
      select jsonb_agg(jsonb_build_object(
        'uk_day', d.uk_day,
        'human', coalesce(g.human, 0),
        'bot_then_human', coalesce(g.bot_then_human, 0),
        'ai_drafted', coalesce(g.ai_drafted, 0),
        'ai_auto', coalesce(g.ai_auto, 0),
        'bot', coalesce(g.bot, 0),
        'no_reply', coalesce(g.no_reply, 0)
      ) order by d.uk_day)
      from days d
      left join g on g.uk_day = d.uk_day
    ), '[]'::jsonb)
  )
$function$;

grant execute on function public.cx_resolution_split_daily(date, date) to authenticated;
