-- Let the app store the English original and language when a reply is written in English and translated on Send.
grant insert (body_en, language) on public.reply_queue to authenticated;
