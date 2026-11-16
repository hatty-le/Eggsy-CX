-- Apply the approved Inbox bracket-note split.
-- Do not run this until docs/draft-note-split-dry-run.md has been reviewed.
--
-- The first argument must be true or the function refuses to write.
-- Auto-send is suppressed while drafts are rewritten, so removing a bracket
-- does not itself email a customer.
-- The second argument is p_queue. false leaves the rewritten drafts where they
-- are. true then calls cx_queue_ready_draft for each one, which still applies
-- every existing hold (US/EU refunds, already replied, Amazon plain text,
-- flags, junk, missing photos, partial history).
select *
  from public.cx_apply_draft_note_split(true, false);
