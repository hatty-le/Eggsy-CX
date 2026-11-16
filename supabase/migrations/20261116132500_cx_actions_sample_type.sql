-- New ticket action: 'sample' (a free creator/influencer sample), alongside replacement, refund and return.
alter table public.cx_actions drop constraint if exists cx_actions_type_check;
alter table public.cx_actions add constraint cx_actions_type_check
  check (type = any (array['replacement','refund','return','sample']));
