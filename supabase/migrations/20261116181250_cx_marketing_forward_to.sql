-- Where "Send to marketing" delivers a ticket. One row, so the address can be changed
-- without a code deploy: update public.cx_settings set value = '"someone@luckyegg.co"'
-- where key = 'marketing_forward_to';
-- The forwarder only accepts @luckyegg.co and falls back to will.h@luckyegg.co if this is missing or invalid.
insert into public.cx_settings (key, value, updated_at, updated_by)
values ('marketing_forward_to', to_jsonb('will.h@luckyegg.co'::text), now(), 'Eggsy')
on conflict (key) do nothing;
