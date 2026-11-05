-- Metrics: team replies sent through Eggsy CX vs on the native platform, by channel.
create or replace function public.cx_reply_route_split(p_from date, p_to date)
returns jsonb language sql stable security invoker set search_path = '' as $$
  with m as (
    select c.origin::text as origin, public.cx_channel_group(c.origin::text) as grp,
           (exists (select 1 from public.reply_queue q where q.message_id = m.id and q.status = 'sent')
            or exists (select 1 from public.sent_log s where s.external_id is not null and s.external_id = m.external_id)) as via_eggsy
    from public.messages m join public.conversations c on c.id = m.conversation_id
    where m.direction::text = 'outbound'
      and not public.cx_is_bot_author(m.author)
      and coalesce(m.body, '') !~* '-{5,} ?Forwarded message'
      and coalesce(m.author, '') not in ('Marty Pardoe', 'hey@luckyegg.co')
      and coalesce(c.order_number, '') not like 'EGGSYTEST-%'
      and (m.sent_at at time zone 'Europe/London')::date between p_from and p_to
  ), q as (
    select r.origin::text as origin, public.cx_channel_group(r.origin::text) as grp, true as via_eggsy
    from public.reply_queue r join public.conversations c on c.id = r.conversation_id
    where r.status = 'sent' and r.message_id is null and coalesce(c.order_number, '') not like 'EGGSYTEST-%'
      and (r.sent_at at time zone 'Europe/London')::date between p_from and p_to
  ), x as (select * from m union all select * from q),
  g as (
    select grp, null::text as origin, true as is_total, count(*) as replies,
           count(*) filter (where via_eggsy) as eggsy, count(*) filter (where not via_eggsy) as native
    from x group by grp
    union all
    select grp, origin, false, count(*), count(*) filter (where via_eggsy), count(*) filter (where not via_eggsy)
    from x group by grp, origin
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(g)) from g), '[]'::jsonb),
    'total', (select jsonb_build_object('replies', count(*), 'eggsy', count(*) filter (where via_eggsy), 'native', count(*) filter (where not via_eggsy)) from x))
$$;
grant execute on function public.cx_reply_route_split(date, date) to authenticated;

-- Pull customers' original emails from hey@ into tickets that only hold Eggsy's summary (every 30 minutes).
create or replace function public.cx_fill_originals_call(p_payload jsonb default '{}'::jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare s text; rid bigint;
begin
  select decrypted_secret into s from vault.decrypted_secrets where name = 'eggsy_email_hook_secret';
  select net.http_post(
    url := 'https://xodkbmtylftfmnxfnxxf.supabase.co/functions/v1/fill-originals',
    body := p_payload,
    headers := jsonb_build_object('Content-Type','application/json','x-eggsy-hook', s),
    timeout_milliseconds := 120000) into rid;
  return rid;
end $$;
revoke all on function public.cx_fill_originals_call(jsonb) from public, anon, authenticated;
select cron.unschedule('cx-fill-originals') where exists (select 1 from cron.job where jobname = 'cx-fill-originals');
select cron.schedule('cx-fill-originals', '*/30 * * * *', $c$select public.cx_fill_originals_call('{}'::jsonb)$c$);

-- Every 30 minutes: log replies our team sent from hey@ (Gmail, eDesk via hey@) that never reached Eggsy, so tickets move to Waiting.
select cron.unschedule('cx-fill-sent') where exists (select 1 from cron.job where jobname = 'cx-fill-sent');
select cron.schedule('cx-fill-sent', '15,45 * * * *', $c$select public.cx_fill_originals_call('{"mode":"sent","offset":0}'::jsonb), public.cx_fill_originals_call('{"mode":"sent","offset":30}'::jsonb), public.cx_fill_originals_call('{"mode":"sent","offset":60}'::jsonb), public.cx_fill_originals_call('{"mode":"sent","offset":90}'::jsonb)$c$);
