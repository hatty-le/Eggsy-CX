-- Placeholder guard: no reply that still contains [ ... ] can be queued, sent or marked sent.
-- Separate trigger; existing reply_queue triggers are untouched. Name sorts last so it sees the final body.
create or replace function public.cx_has_placeholder(p_body text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(p_body, '') ~ '\[[^\]]*\]'
$$;
comment on function public.cx_has_placeholder(text) is 'True when the text still contains a [ ... ] placeholder. Used by the reply_queue placeholder guard.';

create or replace function public.reply_queue_placeholder_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status in ('queued','sending','sent')
     and (tg_op = 'INSERT' or new.status is distinct from old.status or new.body is distinct from old.body)
     and public.cx_has_placeholder(new.body) then
    raise exception 'Fill in the [ ] items first: this reply still contains a placeholder (%)',
      substring(new.body from '\[[^\]]*\]')
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
revoke all on function public.reply_queue_placeholder_guard() from public, anon;

drop trigger if exists reply_queue_zz_placeholder_guard on public.reply_queue;
create trigger reply_queue_zz_placeholder_guard
  before insert or update on public.reply_queue
  for each row execute function public.reply_queue_placeholder_guard();
comment on trigger reply_queue_zz_placeholder_guard on public.reply_queue is
  'Refuses queued/sending/sent when the body matches \[[^\]]*\] (Hatty, 3 Nov 2026).';
