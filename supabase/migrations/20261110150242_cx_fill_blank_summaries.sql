-- Safety net so new tickets never land with a blank list heading or empty notes.
-- Placeholders never copy customer message text, subject lines, emails or phone numbers.
-- Existing non-empty overview/summary values are never overwritten.

create or replace function public.cx_default_overview(
  p_topic text,
  p_origin cx_origin,
  p_status cx_status
) returns text
language sql
immutable
set search_path to public
as $$
  select left(
    coalesce(
      nullif(btrim(
        case
          when nullif(btrim(p_topic), '') is not null and btrim(p_topic) <> 'Other'
            then btrim(p_topic)
          else public.cx_channel_label(p_origin)
        end
        || ' — ' ||
        case p_status
          when 'awaiting_customer' then 'waiting on the customer'
          when 'awaiting_approval' then 'draft waiting for approval'
          when 'resolved' then 'resolved, no written summary yet'
          when 'ignored' then 'ignored, no written summary yet'
          else 'open, no written summary yet'
        end
      ), ''),
      'Ticket — no written summary yet'
    ),
    160
  );
$$;

create or replace function public.cx_default_summary(
  p_topic text,
  p_origin cx_origin,
  p_status cx_status,
  p_shop text,
  p_order_number text,
  p_overview text
) returns text
language sql
immutable
set search_path to public
as $$
  select nullif(btrim(concat_ws(
    ' ',
    coalesce(nullif(btrim(p_overview), ''), public.cx_default_overview(p_topic, p_origin, p_status)) || '.',
    case when nullif(btrim(p_order_number), '') is not null then 'Order ' || btrim(p_order_number) || '.' end,
    public.cx_channel_label(p_origin)
      || coalesce(', ' || nullif(btrim(p_shop), ''), '')
      || '.',
    case p_status
      when 'resolved' then 'The ticket is resolved. A fuller summary has not been written yet.'
      when 'ignored' then 'The ticket is marked ignored. A fuller summary has not been written yet.'
      when 'awaiting_customer' then 'Waiting on the customer. A fuller summary has not been written yet.'
      when 'awaiting_approval' then 'A draft is waiting for approval. A fuller summary has not been written yet.'
      else 'A fuller summary has not been written yet.'
    end
  )), '');
$$;

create or replace function public.cx_conversations_fill_blank_summary()
returns trigger
language plpgsql
security definer
set search_path to public
as $$
begin
  if coalesce(btrim(new.overview), '') = '' then
    new.overview := public.cx_default_overview(new.topic, new.origin, new.status);
  end if;
  if coalesce(btrim(new.summary), '') = '' then
    new.summary := public.cx_default_summary(
      new.topic, new.origin, new.status, new.shop, new.order_number, new.overview
    );
  end if;
  return new;
end;
$$;

drop trigger if exists conversations_fill_blank_summary on public.conversations;
create trigger conversations_fill_blank_summary
  before insert or update on public.conversations
  for each row
  execute function public.cx_conversations_fill_blank_summary();

create or replace function public.cx_fill_blank_summaries()
returns integer
language plpgsql
security definer
set search_path to public
as $$
declare n integer := 0;
begin
  with u as (
    update public.conversations c
    set
      overview = case
        when coalesce(btrim(c.overview), '') = '' then public.cx_default_overview(c.topic, c.origin, c.status)
        else c.overview
      end,
      summary = case
        when coalesce(btrim(c.summary), '') = '' then public.cx_default_summary(c.topic, c.origin, c.status, c.shop, c.order_number, c.overview)
        else c.summary
      end
    where coalesce(btrim(c.overview), '') = ''
       or coalesce(btrim(c.summary), '') = ''
    returning c.id
  )
  select count(*) into n from u;
  return n;
end;
$$;

revoke all on function public.cx_fill_blank_summaries() from public;
revoke all on function public.cx_fill_blank_summaries() from anon;
revoke all on function public.cx_fill_blank_summaries() from authenticated;
grant execute on function public.cx_fill_blank_summaries() to postgres, service_role;

revoke all on function public.cx_conversations_fill_blank_summary() from public;
revoke all on function public.cx_conversations_fill_blank_summary() from anon;
revoke all on function public.cx_conversations_fill_blank_summary() from authenticated;

revoke all on function public.cx_default_overview(text, cx_origin, cx_status) from public;
revoke all on function public.cx_default_overview(text, cx_origin, cx_status) from anon;
grant execute on function public.cx_default_overview(text, cx_origin, cx_status) to postgres, service_role;

revoke all on function public.cx_default_summary(text, cx_origin, cx_status, text, text, text) from public;
revoke all on function public.cx_default_summary(text, cx_origin, cx_status, text, text, text) from anon;
grant execute on function public.cx_default_summary(text, cx_origin, cx_status, text, text, text) to postgres, service_role;

do $cron$
begin
  if not exists (select 1 from cron.job where jobname = 'cx-fill-blank-summaries') then
    perform cron.schedule(
      'cx-fill-blank-summaries',
      '7,37 * * * *',
      'select public.cx_fill_blank_summaries()'
    );
  end if;
end;
$cron$;

drop table if exists public._cx_summary_backfill;
