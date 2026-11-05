create or replace function public.cx_email_mark_bounced(p_reply_id uuid, p_bounce_gmail_id text, p_reason text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare r record; why text := rtrim(p_reason, '. ');
begin
  insert into public.email_bounce_seen (gmail_id, reply_queue_id) values (p_bounce_gmail_id, p_reply_id) on conflict do nothing;
  select * into r from public.reply_queue where id = p_reply_id and status = 'sent' and bounced_at is null for update;
  if not found then return false; end if;
  update public.reply_queue set status = 'failed', bounced_at = now(), bounce_gmail_id = p_bounce_gmail_id,
         send_error = 'Not delivered: ' || why || '. The buyer has NOT received this reply. Post it in Seller Central or edit and send again.'
   where id = p_reply_id;
  update public.sent_log set delivery_failed_at = now(), failure_reason = why where reply_queue_id = p_reply_id;
  update public.conversations set flag = 'Reply not delivered: ' || why, flagged_at = now(), status = 'open', updated_at = now()
   where id = r.conversation_id;
  insert into public.messages (conversation_id, direction, author, body, sent_at, external_id, language)
  values (r.conversation_id, 'note', 'Eggsy', 'Eggsy log: the reply sent by email at ' ||
          to_char(r.sent_at at time zone 'Europe/London', 'DD Mon HH24:MI') || ' UK time was NOT delivered: ' || why || '. It needs posting again.',
          now(), 'note:bounce:' || p_reply_id, 'en')
  on conflict (conversation_id, external_id) do nothing;
  return true;
end $$;
revoke all on function public.cx_email_mark_bounced(uuid,text,text) from public, anon, authenticated;
grant execute on function public.cx_email_mark_bounced(uuid,text,text) to service_role;
