-- "Ask Marty" on a ticket logs an open 'advice' follow-up. While it is open the ticket sits in Gaps
-- ("waiting on Marty") and is never auto-sent: cx_draft_readiness returns missing_actions = {marty}.
-- Applied via MCP on 16 Nov 2026; see the database for the full cx_draft_readiness definition.
alter table public.cx_followups drop constraint cx_followups_kind_check;
alter table public.cx_followups add constraint cx_followups_kind_check
  check (kind = any (array['game_idea','product_fault','feedback','advice','other']));
