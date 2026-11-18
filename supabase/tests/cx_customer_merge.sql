-- Rolls back on failure. On success the test rows are deleted before the statement commits.
do $test$
declare
  keep uuid;
  other uuid;
  third uuid;
  landed uuid;
  draft_keep uuid;
  draft_new uuid;
  winner uuid;
  n int;
begin
  if not public.cx_email_is_customer('lauralou40@hotmail.com') then
    raise exception 'customer email should count';
  end if;
  if public.cx_email_is_customer('noreply@ads.amazon.com') then
    raise exception 'amazon ads mailbox should not count';
  end if;
  if public.cx_email_is_customer('mailer@shopify.com') then
    raise exception 'shopify mailer should not count';
  end if;
  if public.cx_email_is_customer('someone@marketplace.amazon.co.uk') then
    raise exception 'amazon relay without a buyer id should not count';
  end if;
  if not public.cx_email_is_customer('5ptbwr6tmrb1gbm+c77b711a-b222-4bc2-aff2-065655aaea59@marketplace.amazon.co.uk') then
    raise exception 'buyer-specific amazon relay should count';
  end if;
  if public.cx_handle_is_customer('@buyer') or public.cx_handle_is_customer('Unknown Instagram user') or public.cx_handle_is_customer('s…') then
    raise exception 'placeholder handle should not count';
  end if;
  if not public.cx_handle_is_customer('@gabyka__') then
    raise exception 'tiktok handle should count';
  end if;
  if public.cx_order_family('email_hey', 'Lucky Egg', '#11456') is distinct from 'le_gb' then
    raise exception 'GB order family';
  end if;
  if public.cx_order_family('shopify_form', 'Lucky Egg (US)', '11456') is distinct from 'le_us' then
    raise exception 'US order family';
  end if;
  if public.cx_order_family('amazon_uk', 'Amazon UK', '111-1234567-1234567') is distinct from 'amazon' then
    raise exception 'amazon order family';
  end if;

  insert into public.conversations (origin, shop, customer_name, customer_handle, subject, order_number, status, external_id, last_message_at)
  values ('shopify_form', 'Lucky Egg (GB)', 'Test Merge', 'test-merge-a@example.com', 'form', '11456', 'resolved', 'test-merge:keep', now() - interval '2 days')
  returning id into keep;
  update public.conversations set status_changed_at = now() - interval '2 days' where id = keep;

  insert into public.conversations (origin, shop, customer_name, customer_handle, subject, status, external_id, last_message_at)
  values ('email_hey', 'Lucky Egg', 'Test Merge', 'Test Merge <test-merge-a@example.com>', '11456', 'open', 'test-merge:email', now())
  returning id into other;
  if (select merged_into from public.conversations where id = other) is distinct from keep then
    raise exception 'same email should attach to the existing ticket';
  end if;

  insert into public.messages (conversation_id, direction, author, body, sent_at, external_id, origin)
  values (other, 'inbound', 'Test Merge', 'Following up on 11456', now(), 'test-merge:msg', 'email_hey')
  returning conversation_id into landed;
  if landed is distinct from keep then
    raise exception 'message on a merged shell should land on the kept ticket';
  end if;
  if (select origin from public.messages where external_id = 'test-merge:msg') is distinct from 'email_hey' then
    raise exception 'message should keep the channel it arrived on';
  end if;
  if (select status from public.conversations where id = keep) is distinct from 'open' then
    raise exception 'a new inbound on a resolved ticket should reopen it';
  end if;

  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id)
  values ('tiktok_uk', 'TikTok UK', 'One', '@buyer', 'open', 'test-merge:buyer1');
  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id)
  values ('tiktok_uk', 'TikTok UK', 'Two', '@buyer', 'open', 'test-merge:buyer2')
  returning id into third;
  if (select merged_into from public.conversations where id = third) is not null then
    raise exception '@buyer must not merge';
  end if;

  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id)
  values ('email_hey', 'Lucky Egg', 'Amazon Ads', 'noreply@ads.amazon.com', 'open', 'test-merge:ads1');
  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id)
  values ('email_hey', 'Lucky Egg', 'Amazon Ads', 'noreply@ads.amazon.com', 'open', 'test-merge:ads2')
  returning id into third;
  if (select merged_into from public.conversations where id = third) is not null then
    raise exception 'platform mailbox must not merge';
  end if;

  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id)
  values ('amazon_uk', 'Amazon UK', 'Buyer', 'abc123+11111111-1111-1111-1111-111111111111@marketplace.amazon.co.uk', 'open', 'test-merge:relay1');
  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id)
  values ('email_hey', 'Lucky Egg', 'Buyer', 'abc123+11111111-1111-1111-1111-111111111111@marketplace.amazon.co.uk', 'open', 'test-merge:relay2')
  returning id into third;
  if (select merged_into from public.conversations where id = third) is null
     and (select merged_into from public.conversations where external_id = 'test-merge:relay1') is null then
    raise exception 'buyer-specific amazon relay should merge';
  end if;

  insert into public.conversations (origin, shop, customer_name, customer_handle, order_number, status, external_id)
  values ('shopify_form', 'Lucky Egg (US)', 'US Order', 'test-merge-us@example.com', '11456', 'open', 'test-merge:us')
  returning id into third;
  if (select merged_into from public.conversations where id = third) is not null then
    raise exception 'the same order number in another shop must not merge';
  end if;

  insert into public.conversations (origin, shop, customer_name, customer_handle, order_number, status, external_id)
  values ('email_hey', 'Lucky Egg', 'Name Only', 'test-merge-name-a@example.com', null, 'open', 'test-merge:name1');
  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id)
  values ('shopify_form', 'Lucky Egg (GB)', 'Name Only', 'test-merge-name-b@example.com', 'open', 'test-merge:name2')
  returning id into third;
  if (select merged_into from public.conversations where id = third) is not null then
    raise exception 'a shared name must not merge';
  end if;

  insert into public.conversations (origin, shop, customer_name, customer_handle, order_number, status, external_id)
  values ('email_hey', 'Lucky Egg', 'Rosie One', 'test-merge-rosie-a@example.com', '10709', 'resolved', 'test-merge:rosie1');
  insert into public.conversations (origin, shop, customer_name, customer_handle, order_number, status, external_id)
  values ('email_hey', 'Lucky Egg', 'Rosie Two', 'test-merge-rosie-b@example.com', '10709', 'open', 'test-merge:rosie2')
  returning id into third;
  if (select merged_into from public.conversations where id = third) is not null then
    raise exception 'one order number with two emails is ambiguous';
  end if;

  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id, last_message_at)
  values ('tiktok_uk', 'TikTok UK', 'Handle', '@testmergehandle', 'open', 'test-merge:hand1', now() - interval '1 day')
  returning id into keep;
  insert into public.messages (conversation_id, direction, author, body, sent_at, external_id)
  values (keep, 'inbound', 'Handle', 'older handle message', now() - interval '1 day', 'test-merge:hand1-msg');
  insert into public.suggested_drafts (conversation_id, body, author, drafted_at, superseded)
  values (keep, 'older draft', 'Eggsy', now() - interval '1 day', false)
  returning id into draft_keep;

  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id, last_message_at)
  values ('tiktok_uk', 'TikTok UK', 'Handle', '@testmergehandle', 'awaiting_customer', 'test-merge:hand2', now())
  returning id into other;
  -- The insert trigger already merged this shell. Put a draft on the kept ticket as if it arrived with the new thread.
  insert into public.suggested_drafts (conversation_id, body, author, drafted_at, superseded, source_conversation_id)
  values (other, 'newer draft', 'Eggsy', now(), false, other)
  returning id into draft_new;
  if (select conversation_id from public.suggested_drafts where id = draft_new) is distinct from keep then
    raise exception 'a draft inserted on the shell should move to the kept ticket';
  end if;

  -- Ingest attaches the shell but leaves both drafts current. A staff merge collapses them.
  perform public.cx_unmerge_conversation(other);
  perform public.cx_merge_conversations(keep, other);
  select count(*) into n from public.suggested_drafts where conversation_id = keep and superseded = false;
  if n <> 1 then
    raise exception 'one draft should stay current, found %', n;
  end if;
  if (select id from public.suggested_drafts where conversation_id = keep and superseded = false) is distinct from draft_new then
    raise exception 'the newest draft should stay current';
  end if;

  perform public.cx_unmerge_conversation(other);
  if (select merged_into from public.conversations where id = other) is not null then
    raise exception 'unmerge should clear merged_into';
  end if;
  if (select conversation_id from public.suggested_drafts where id = draft_new) is distinct from other then
    raise exception 'unmerge should put the newer draft back';
  end if;

  insert into public.messages (conversation_id, direction, author, body, sent_at, external_id, origin)
  values (keep, 'inbound', 'Handle', 'latest customer message', now(), 'test-merge:hand-late', 'tiktok_uk');
  if public.cx_reply_origin(keep, null) is distinct from 'tiktok_uk' then
    raise exception 'reply channel should be the latest customer message';
  end if;
  if public.cx_reply_origin(keep, 'email_hey') is distinct from 'tiktok_uk' then
    raise exception 'a channel that is not on the ticket should be ignored';
  end if;

  delete from public.cx_conversation_merges
   where keep_id in (select id from public.conversations where external_id like 'test-merge:%')
      or merged_id in (select id from public.conversations where external_id like 'test-merge:%');
  delete from public.conversations where external_id like 'test-merge:%';

  if public.cx_email_is_customer('buyer@scs3.tiktok.com') then
    raise exception 'a TikTok scs relay address must not be a customer email';
  end if;
  if public.cx_tiktok_subject_handle('A new message from TikTok Shop customer statuschaser') is distinct from 'statuschaser' then
    raise exception 'subject handle';
  end if;
  insert into public.conversations (origin, shop, customer_name, customer_handle, status, external_id)
  values ('tiktok_uk', 'TikTok UK', 'statuschaser-test', '@statuschaser-test', 'awaiting_customer', 'test-merge:tt-chat')
  returning id into keep;
  insert into public.conversations (origin, shop, customer_name, customer_handle, subject, status, external_id)
  values ('tiktok_uk', 'TikTok UK', 'TikTok Shop Seller Assistant', 'abc@scs3.tiktok.com', 'A new message from TikTok Shop customer statuschaser-test', 'open', 'test-merge:tt-mail')
  returning id into other;
  if (select merged_into from public.conversations where id = other) is distinct from keep then
    raise exception 'Seller Assistant mail should join the buyer TikTok chat';
  end if;
  insert into public.reply_queue (conversation_id, body) values (other, 'test-merge queued reply');
  perform public.cx_unmerge_conversation(other);
  perform set_config('eggsy.skip_reply_queue', 'on', true);
  perform public.cx_merge_conversations(keep, other);
  if (select conversation_id from public.reply_queue where body = 'test-merge queued reply') is distinct from other then
    raise exception 'a queued reply must stay on its original ticket';
  end if;
  delete from public.reply_queue where body = 'test-merge queued reply';
  delete from public.cx_conversation_merges where merged_id = other or keep_id = keep;
  delete from public.conversations where external_id like 'test-merge:tt-%';
end
$test$;
