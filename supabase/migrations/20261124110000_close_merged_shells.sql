-- Merged-away tickets are omitted from cx_conversation_state. The inbox page
-- treated a missing state row as "needs a reply" when status was still open,
-- so those shells were counted on the TikTok badge and were not a real region
-- list. The surviving ticket is already resolved. Close the shell.
update public.conversations c
   set status = 'resolved',
       updated_at = now()
  from public.conversations p
 where c.merged_into = p.id
   and c.status not in ('resolved', 'ignored')
   and p.status in ('resolved', 'ignored');
