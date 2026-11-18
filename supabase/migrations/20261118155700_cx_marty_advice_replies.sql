-- Applied via MCP on 18 Nov 2026. Marty's email reply to an "Email to Marty for advice" comes back to hey@
-- on the same Gmail thread; trigger messages_ab_marty_advice (function public.cx_marty_advice_reply) files it
-- on the customer's ticket as a "(Marty's advice)" note, closes the advice follow-up and supersedes the draft
-- so the hourly drafter redrafts using the advice. It also drops our own advice email if the hey@ sync tries to
-- log it as an outbound reply. cx_followups.gmail_thread_id links a follow-up to the advice email thread.
-- Full definition: see the database (pg_get_functiondef('public.cx_marty_advice_reply'::regproc)).
alter table public.cx_followups add column if not exists gmail_thread_id text;
