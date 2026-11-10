-- Search inside message text (original and English translation) across every ticket, for the Inbox/Waiting/Resolved search box.
create or replace function public.cx_search_messages(p_q text)
returns table(conversation_id uuid, snippet text)
language sql stable security invoker set search_path = '' as $$
  with hits as (
    select m.conversation_id, coalesce(case when m.body ilike '%' || p_q || '%' then m.body end, m.body_en) as txt, m.sent_at,
           row_number() over (partition by m.conversation_id order by m.sent_at desc) as rn
    from public.messages m
    where length(btrim(p_q)) >= 3
      and m.direction::text in ('inbound', 'outbound')
      and (m.body ilike '%' || p_q || '%' or m.body_en ilike '%' || p_q || '%')
  )
  select h.conversation_id,
         substr(regexp_replace(h.txt, '\s+', ' ', 'g'),
                greatest(1, strpos(lower(regexp_replace(h.txt, '\s+', ' ', 'g')), lower(btrim(p_q))) - 50), 160)
  from hits h where h.rn = 1
  limit 300
$$;
grant execute on function public.cx_search_messages(text) to authenticated;
