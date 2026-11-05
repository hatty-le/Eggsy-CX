-- Per conversation: Eggsy's current draft, how many [ ] notes it has, and which promised actions (replacement/refund/return)
-- are not logged yet. Uses the same check as the send guard, so "Ready" drafts will not be blocked at Send.
create or replace function public.cx_draft_readiness()
returns table(conversation_id uuid, notes int, missing_actions text[], drafted_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select d.conversation_id,
         coalesce((select count(*)::int from regexp_matches(d.body, '\[[^\]]*\]', 'g')), 0),
         coalesce((select array_agg(t) from unnest(public.cx_promised_action_types(d.body, false)) t
                   where not exists (select 1 from public.cx_actions a
                                     where a.conversation_id = d.conversation_id
                                       and (t = 'any' or a.type = t)
                                       and a.status in ('created', 'done', 'expected', 'received'))), '{}'),
         d.drafted_at
  from public.suggested_drafts d
  where not d.superseded
$$;
grant execute on function public.cx_draft_readiness() to authenticated;

-- Also flag drafts written without the full chat (a message stored only as Eggsy's summary, with no verbatim copy alongside).
drop function if exists public.cx_draft_readiness();
create function public.cx_draft_readiness()
returns table(conversation_id uuid, notes int, missing_actions text[], partial_history boolean, drafted_at timestamptz)
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
         d.drafted_at
  from public.suggested_drafts d
  where not d.superseded
$$;
grant execute on function public.cx_draft_readiness() to authenticated;
