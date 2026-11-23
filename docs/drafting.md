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

## Who drafts

There are two drafters and they share one path. The Eggsy drafter saves with author `Eggsy`. The batch drafter saves with author `Claude`. Both read the published knowledge articles from `kb_for_origin` (there is no separate prompt file) and both save with `cx_save_draft`. The pre-queue check in `cx_queue_ready_draft` is the same for both.

## Greenlit auto-send types

Hatty greenlit five types on 23 Nov 2026. The article "Greenlit auto-send replies" is the rule both drafters follow. The drafter does the lookup and records any follow-up as a `cx_actions` row. It does not write `[check tracking]`, `[is this spam?]` or `[forward to sales]` in the draft.

`p_reply_type` is one of `tracking_update`, `address_confirmation`, `wholesale_holding`, `thank_you`, `junk_decision`. `p_reply_facts` is the lookup (order found, shipping status, and for an address check whether it matched and whether it has shipped). Turn a type off later with:

```sql
update public.cx_settings
   set value = jsonb_set(value, '{tracking_update}', 'false')
 where key = 'auto_send_greenlit_types';
```

`cx_greenlit_prequeue_block` runs after the existing holds and before anything is auto-queued. It blocks a tracking reply that mentions a refund, replacement, compensation or a delivery date, or whose lookup is missing or shows delivered, lost, failed, returned or an exception. It blocks an address reply that says the address was changed without a recorded change, or that is shipped, unmatched, or not looked up. It blocks a wholesale reply that contains £, $, €, a price next to a number, minimum, MOQ, discount or terms. It blocks a thank-you to a creator, influencer, UGC, ad-code or sample ticket, and a thank-you that makes a promise. Junk is not queued. Drafts saved before `auto_send_greenlit_from` are left on the previous rules.

A wholesale save also writes a pending follow-up to Ben Pullen (sales), with the same `to`, `to_name` and `kind` fields as a colleague forward. It does not call the automatic colleague forward, because that mailer resolves the ticket.

Replacement follow-ups, gameplay questions, missing parts, cancellations, UK damaged items and refunds are unchanged. So are the US/EU refund hold, Amazon plain-text rules, the neighbours-first delivered-not-arrived steps, the promised-action check, the already-answered check, and the rule that we never say the artwork is not AI.

```sql
select * from public.cx_greenlit_dry_run();
```

That read is the dry run for drafts already in the Inbox. It does not change a draft and it does not send anything. `would_ready` is true only when the customer text is already complete and every hold, including the new check, would let it queue.

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
