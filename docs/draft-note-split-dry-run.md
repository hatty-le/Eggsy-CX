# Draft bracket-note dry run

Read-only classification of square-bracket notes on current Inbox drafts. No draft was rewritten and no reply was queued by this run. Re-run with `select * from public.cx_draft_note_split_report();` or `scripts/draft-note-split-dry-run.sql`. Apply later, only after this is approved, with `scripts/apply-draft-note-split.sql` (`cx_apply_draft_note_split(true, false)`). That rewrite suppresses auto-send while it updates rows.

Generated 16 Nov 2026 from Supabase project `xodkbmtylftfmnxfnxxf`. The row-level file is `docs/draft-note-split-dry-run.csv`.

## Counts

140 bracket notes on 127 Inbox tickets.

| Class | Notes | Tickets touched |
| --- | ---: | ---: |
| Blocking | 123 | 110 |
| Follow-up | 11 | 11 |
| Info | 6 | 6 |

10 of those 127 tickets would become auto-sendable: the reply has no blocking bracket left, and every existing safety hold in `cx_queue_ready_draft` would pass.

| Channel | Would auto-send |
| --- | ---: |
| Email (hey@) | 2 |
| Website form | 5 |
| TikTok UK | 3 |

The other 117 stay held. 111 are still `not_ready` (a blocking bracket, or another readiness gap). 5 Wix tickets whose only note is the disabled send route are context, and `no_send_path` still stops them. 1 Amazon follow-up (Daniel, parcel found) is not sent because the reply contains an emoji (`amazon_not_plain`).

## Examples

**Blocking.** The reply still has a hole, or a decision changes what we tell the customer.

- Amazon DE, Anna: "Amazon DE (EU): parcel missing since 11 Nov… Hatty and Kim: check the tracking… and decide on a re-send or refund. Do not promise either."
- Amazon ES, Cordula: "Sí, este juego está en español. / No, esta versión del juego no está en español." (a choice still sitting in the reply)
- Shopify form, Laura Sanderson: "add tracking number" and "add latest tracking status" inside the reply, plus "if it has shipped, add the tracking number… if it has not shipped, change the reply."

**Follow-up.** The reply is already accurate. The note becomes a pending `follow_up` action with an owner team.

- Email, Dean Hipwell / CDH Racing, marketing: "Delete this draft if not interested, or send this holding reply and follow up." The reply already says the pitch has been passed to marketing. This one would auto-send.
- Email, Hayley Lozitsky, directors: forward the TV-show enquiry to Luke, then send or delete the holding reply. Would auto-send.
- Website form, Grace Raggett, product: illustrator enquiry; "decide whether to follow up, then send or delete this holding reply." Would auto-send.
- Amazon US, Daniel, CX: "Daniel found the parcel… close the pending replacement action." The follow-up is real, but the reply still has an emoji, so Amazon plain-text holds it.

**Info.** Context for the reader, not counted as a bracket, and not a job.

- Wix form, Jan Fletcher (and the same note on five other Wix tickets): "Wix new-email send channel is disabled. Customer reply requires an enabled/authorised send route, not a direct-send bypass." The reply text has no gap. Auto-send still returns `no_send_path` until that channel is enabled. A Wix note that also needs a human decision (for example a puzzle solution or a policy review) stays blocking.
