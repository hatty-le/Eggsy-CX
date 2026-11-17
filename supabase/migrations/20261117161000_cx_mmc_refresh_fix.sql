-- The first refresh function used a variable named flag, which clashes with conversations.flag.
-- Replace it, then backfill. Safe to re-run: the function is the same as the corrected
-- definition and the backfill only writes is_mmc.

create or replace function public.cx_refresh_conversation_mmc(p_id uuid)
returns boolean
language plpgsql
volatile
set search_path = ''
as $fn$
declare
  r public.conversations%rowtype;
  txt text;
  mmc_flag boolean;
begin
  select * into r from public.conversations where id = p_id;
  if not found then
    return false;
  end if;

  if r.status::text = 'ignored' then
    if r.is_mmc then
      update public.conversations set is_mmc = false where id = p_id;
    end if;
    return false;
  end if;

  select string_agg(
    coalesce(m.author, '') || ' ' ||
    coalesce(m.body, '') || ' ' ||
    coalesce(m.body_en, '') || ' ' ||
    coalesce(m.body_raw, ''),
    E'\n'
  )
    into txt
  from public.messages m
  where m.conversation_id = p_id
    and m.direction::text = 'inbound';

  mmc_flag := public.cx_is_mmc(r.status::text, r.origin::text, r.subject, r.shop, r.customer_handle, txt);
  if r.is_mmc is distinct from mmc_flag then
    update public.conversations set is_mmc = mmc_flag where id = p_id;
  end if;
  return mmc_flag;
end
$fn$;

revoke all on function public.cx_refresh_conversation_mmc(uuid) from public, anon;
grant execute on function public.cx_refresh_conversation_mmc(uuid) to authenticated, service_role;

do $backfill$
declare
  r record;
begin
  for r in select id from public.conversations loop
    perform public.cx_refresh_conversation_mmc(r.id);
  end loop;
end
$backfill$;
