-- The app sends requires_action with every reply (added in cx_actions_layer), but staff could only insert conversation_id and body,
-- so every Send failed with "permission denied for table reply_queue". The action guard trigger still checks the flag.
grant insert (requires_action) on public.reply_queue to authenticated;
