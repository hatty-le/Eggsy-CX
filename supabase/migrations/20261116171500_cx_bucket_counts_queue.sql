-- Adds 'queue' to cx_bucket_counts: replies queued or sending, shown on the Send queue page.
create or replace function public.cx_bucket_counts()
 returns json language sql stable set search_path to ''
as $function$
  select json_build_object(
    'inbox', count(*) filter (where bucket = 'inbox'),
    'waiting', count(*) filter (where bucket = 'waiting'),
    'resolved', count(*) filter (where bucket = 'resolved'),
    'junk', count(*) filter (where bucket = 'junk'),
    'actions', (select count(*) from public.cx_followups where status = 'open'),
    'queue', (select count(*) from public.reply_queue where status in ('queued','sending')))
  from public.cx_conversation_state
$function$;
