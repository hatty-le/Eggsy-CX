# How Eggsy drafts a reply

Eggsy writes the customer-facing reply, and keeps anything that is not for the customer out of that reply. The knowledge article "How we write replies: tone, structure and sign-off" carries the same rule. Save the draft with `public.cx_save_draft`.

## What goes where

**Blocking gap.** The reply is missing a fact, or a decision would change the words we send. Examples: the order lookup is not back, stock or a date is unknown, a policy choice changes the reply, or a person must approve it first (US and EU refunds). Pass these as `p_blocking_notes`. They are stored as square brackets at the top of the draft body. Brackets keep the draft in Gaps and stop auto-send.

**Follow-up.** The reply is already accurate, and something still has to happen inside Lucky Egg. Examples: pass it to marketing, send the replacement the reply says we will arrange, check with the warehouse and follow up, update the knowledge base, log a sample, chase another team. Pass these as `p_follow_up_actions`. Each one becomes a pending row in `cx_actions` with type `follow_up`, a description, and an owner team: `marketing`, `warehouse`, `product`, `cx`, `directors`, `ops`, `sales`, or `finance`. A pending follow-up does not block auto-send. It shows on the ticket and on the Actions page, with a Done button.

**Context.** A note for the person reading the ticket, with no gap and no job. Pass it as `p_context`. It is stored on `suggested_drafts.context`, shown above the reply, and is not counted as a bracket note.

Do not put follow-ups or context in square brackets. Brackets are only for blocking gaps.

## Saving a draft

```sql
select public.cx_save_draft(
  '<conversation uuid>'::uuid,
  '<customer reply, with no brackets>',
  ARRAY['<blocking gap>']::text[],          -- empty array when the reply is complete
  '[{"description":"<what to do>","owner_team":"marketing"}]'::jsonb,
  '<internal context, or null>'
);
```

`cx_save_draft` supersedes the current draft, stores the new one, and logs the follow-ups. The draft insert can auto-send when there are no blocking brackets and every existing safety hold passes: US/EU refund escalation, a reply that already went out, Amazon text that is not plain, flags, junk, a missing photo, and a chat that is only an Eggsy summary.

`missing_actions` on `cx_draft_readiness()` is only an open "Ask Marty" follow-up, or a replacement, refund, or return the reply says is already done and that is not logged. Pending `follow_up` actions are not in that list.

## Dry run for drafts already in the Inbox

`public.cx_draft_note_split_report()` reads the current Inbox drafts and classifies each bracket note. It does not change a draft and it does not send anything.

```sql
select * from public.cx_draft_note_split_report();
```

`would_auto_send` is true when removing the follow-up and context notes would leave a draft that `cx_queue_ready_draft` would queue. `hold` is the reason when it would not (`not_ready`, `us_eu_refund_escalate`, `already_replied`, `amazon_not_plain:…`, `no_send_path`, `flagged`, and the other existing holds).

The latest run is in `docs/draft-note-split-dry-run.md` and `docs/draft-note-split-dry-run.csv`.

## Applying the split later

Do not run this until that report is approved. It rewrites Inbox drafts: follow-up notes become actions, context notes move to `context`, and blocking brackets stay. Auto-send is suppressed while the rows are rewritten, so the act of removing a bracket does not itself email a customer.

```sql
select * from public.cx_apply_draft_note_split(true, false);
```

The second argument queues the drafts that then pass every safety hold in `cx_queue_ready_draft`. Leave it `false` unless that queue is wanted in the same step. The script is `scripts/apply-draft-note-split.sql`. The app cannot call this function; it runs as `postgres` or `service_role`.
