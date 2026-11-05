-- Set when a customer email that had a photo or file is no longer in hey@, so the attachment can't be shown.
alter table public.messages add column if not exists attachment_missing boolean not null default false;

drop function if exists public.cx_draft_readiness();
create function public.cx_draft_readiness()
returns table(conversation_id uuid, notes int, missing_actions text[], partial_history boolean, attachment_missing boolean, drafted_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select d.conversation_id,
         coalesce((select count(*)::int from regexp_matches(d.body, '\[[^\]]*\]', 'g')), 0),
         coalesce((select array_agg(t) from unnest(public.cx_promised_action_types(d.body, false)) t
                   where not exists (select 1 from public.cx_actions a
                                     where a.conversation_id = d.conversation_id
                                       and (t = 'any' or a.type = t)
                                       and a.status in ('created', 'done', 'expected', 'received'))), '{}'),
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
$$;
grant execute on function public.cx_draft_readiness() to authenticated;

-- Hourly: re-check which customer emails with photos/files are missing from hey@.
select cron.unschedule('cx-attachment-missing') where exists (select 1 from cron.job where jobname = 'cx-attachment-missing');
select cron.schedule('cx-attachment-missing', '20 * * * *', $c$select public.cx_fill_originals_call('{"mode":"missing","offset":0}'::jsonb), public.cx_fill_originals_call('{"mode":"missing","offset":40}'::jsonb), public.cx_fill_originals_call('{"mode":"missing","offset":80}'::jsonb), public.cx_fill_originals_call('{"mode":"missing","offset":120}'::jsonb)$c$);
