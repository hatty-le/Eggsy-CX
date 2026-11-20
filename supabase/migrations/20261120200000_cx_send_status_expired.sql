-- New reply_queue status for replies the platform can no longer deliver.
-- Added on its own: Postgres will not accept a new enum value in the same
-- transaction that uses it. The following migration installs the window rules.

alter type public.cx_send_status add value if not exists 'expired';
