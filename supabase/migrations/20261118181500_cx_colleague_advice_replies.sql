-- Applied via MCP on 18 Nov 2026: cx_marty_advice_reply() now works for any colleague picked in the Forward panel.
-- The reply note reads "(<Name>'s advice) ..." (name from the advice follow-up's assignees, "Name <email>"),
-- and our own forward/advice emails are dropped if the hey@ sync tries to log them as replies to the customer.
-- Full definition: pg_get_functiondef('public.cx_marty_advice_reply'::regproc).
select 1;
