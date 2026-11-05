alter table public.messages add column if not exists language text, add column if not exists body_en text;
alter table public.messages add constraint messages_language_iso check (language is null or language ~ '^[a-z]{2}$');
comment on column public.messages.language is 'ISO 639-1 code of body (en, de, nl, it, sv, es, fr...)';
comment on column public.messages.body_en is 'Faithful English translation of body; null when body is already English';
update public.suggested_drafts set language = case lower(language) when 'german' then 'de' when 'dutch' then 'nl' when 'italian' then 'it' when 'swedish' then 'sv' when 'spanish' then 'es' when 'french' then 'fr' when 'english' then 'en' else lower(language) end where language is not null;
alter table public.suggested_drafts add constraint suggested_drafts_language_iso check (language is null or language ~ '^[a-z]{2}$');
comment on column public.suggested_drafts.language is 'ISO 639-1 code of body; body_en holds the English translation when not en';