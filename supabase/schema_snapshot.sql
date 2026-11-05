-- Eggsy CX schema snapshot (current live public schema as of 2026-11-05)
-- Migrations in supabase/migrations/ are complete (16/16, SQL retrieved from
-- supabase_migrations.schema_migrations). This file is an inventory of what is
-- live, not a substitute for those migrations. No secret values are included.

-- Public tables
--   conversations
--   messages
--   reply_queue
--   sent_log
--   suggested_drafts
--   email_send_channels
--   email_bounce_seen
--   kb_articles
--   cx_actions
--   gmail_sync_state

-- Public functions (name + arguments)
--   conversations_status_stamp()
--   cx_action_metrics(p_from date, p_to date)
--   cx_actions_call(p_payload jsonb)
--   cx_bucket_counts()
--   cx_channel_group(o text)
--   cx_channel_label(o cx_origin)
--   cx_email_call(p_payload jsonb)
--   cx_email_hook_ok(p_secret text)
--   cx_email_mark_bounced(p_reply_id uuid, p_bounce_gmail_id text, p_reason text)
--   cx_email_mark_sent(p_reply_id uuid, p_gmail_id text, p_thread_id text, p_message_id_hdr text)
--   cx_gmail_call(p_payload jsonb)
--   cx_gmail_hook_ok(p_secret text)
--   cx_has_placeholder(p_body text)
--   cx_is_internal_outbound(p_author text, p_body text)
--   cx_log_action_note(p_conversation_id uuid, p_body text, p_external_id text)
--   cx_log_sent_reply(p_origin cx_origin, p_body text, p_route text, p_sent_at timestamptz, p_conversation_id uuid, p_conv_external_id text, p_order_number text, p_customer_name text, p_customer_handle text, p_shop text, p_subject text, p_external_id text, p_approved_by text, p_author text)
--   cx_metrics(p_from date, p_to date, p_baseline_hours numeric)
--   cx_promised_action_types(p_body text, p_flag boolean)
--   cx_shopify_admin_token()
--   is_lucky_egg_staff()
--   kb_articles_touch()
--   kb_for_origin(p_origin cx_origin, p_language text)
--   messages_reopen_on_inbound()
--   reply_queue_action_guard()
--   reply_queue_before_insert()
--   reply_queue_before_update()
--   reply_queue_email_kick()
--   reply_queue_log_sent()
--   reply_queue_placeholder_guard()
--   sent_log_before_insert()
--   touch_conversation()

-- Triggers
CREATE TRIGGER conversations_status_stamp BEFORE INSERT OR UPDATE OF status ON public.conversations FOR EACH ROW EXECUTE FUNCTION conversations_status_stamp();
CREATE TRIGGER kb_articles_touch BEFORE INSERT OR UPDATE ON public.kb_articles FOR EACH ROW EXECUTE FUNCTION kb_articles_touch();
CREATE TRIGGER messages_reopen_on_inbound AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION messages_reopen_on_inbound();
CREATE TRIGGER messages_touch_conversation AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION touch_conversation();
CREATE TRIGGER reply_queue_action_guard BEFORE INSERT OR UPDATE ON public.reply_queue FOR EACH ROW EXECUTE FUNCTION reply_queue_action_guard();
CREATE TRIGGER reply_queue_before_insert BEFORE INSERT ON public.reply_queue FOR EACH ROW EXECUTE FUNCTION reply_queue_before_insert();
CREATE TRIGGER reply_queue_before_update BEFORE UPDATE ON public.reply_queue FOR EACH ROW EXECUTE FUNCTION reply_queue_before_update();
CREATE TRIGGER reply_queue_email_kick AFTER INSERT ON public.reply_queue FOR EACH ROW EXECUTE FUNCTION reply_queue_email_kick();
CREATE TRIGGER reply_queue_log_sent AFTER INSERT OR UPDATE OF status ON public.reply_queue FOR EACH ROW EXECUTE FUNCTION reply_queue_log_sent();
CREATE TRIGGER reply_queue_zz_placeholder_guard BEFORE INSERT OR UPDATE ON public.reply_queue FOR EACH ROW EXECUTE FUNCTION reply_queue_placeholder_guard();
CREATE TRIGGER sent_log_before_insert BEFORE INSERT ON public.sent_log FOR EACH ROW EXECUTE FUNCTION sent_log_before_insert();

-- pg_cron jobs (live)
-- jobid 1  eggsy-email-sweep     */3 * * * *     select public.cx_email_call('{"mode":"sweep"}'::jsonb)            active
-- jobid 2  cx-actions-tracking   20,50 * * * *   select public.cx_actions_call('{"action":"refresh_tracking"}'::jsonb)  active
-- jobid 3  gmail-hey-sync        */5 * * * *     select public.cx_gmail_call('{"mode":"sync"}'::jsonb)             active
-- jobid 4  gmail-hey-watch       20 3 * * *      select public.cx_gmail_call('{"mode":"watch"}'::jsonb)            active
--
-- Note: gmail-hey-sync and gmail-hey-watch are cron jobs that POST to the
-- gmail-push edge function. They are not separate edge functions.
