# Eggsy CX

Lucky Egg’s customer-service tracker. Staff at `@luckyegg.co` sign in with a 6-digit email code, then work tickets across email (hey@), Amazon, TikTok, Shopify, Walmart and Meta from one inbox.

Live site: https://eggsy-cx.vercel.app

This repo was assembled from the current production sources (the code was not in git before):

- Website: Vercel project `eggsy-cx` (`prj_lTp0x5l17WaKNdU4XbGjXfBPbaHR`), production deployment used: `dpl_GsxH6ge2rCDLwYn812XrPfYYiNBp` (files fetched from https://eggsy-cx.vercel.app on 5 Nov 2026 Europe/London).
- Database migrations and edge functions: Supabase project `xodkbmtylftfmnxfnxxf` (lucky-egg-cs-tracker, eu-west-2).

## Layout

```
site/                          static web app (deploy this folder to Vercel)
  index.html                   home
  nav.js                       shared left-hand menu
  inbox/ index.html            inbox (same app also served at /waiting/ and /resolved/)
  waiting/ index.html
  resolved/ index.html
  knowledge/ index.html
  metrics/ index.html
  sent/ index.html
supabase/
  migrations/                  16 dated SQL migrations (complete)
  functions/
    send-email-reply/          email relay (hey@) for approved replies and bounce sweep
    cx-actions/                replacements, refunds, returns, tracking refresh
    gmail-push/                hey@ Gmail push + history sync + watch renewal
  schema_snapshot.sql          live public-schema inventory (tables, functions, triggers, cron)
```

`gmail-hey-sync` (every 5 minutes) and `gmail-hey-watch` (daily 03:20 UTC) are **pg_cron jobs**, not edge functions. They call `public.cx_gmail_call`, which POSTs to the `gmail-push` function.

## Deploy

### Website (Vercel)

Project name: `eggsy-cx`. Team: hatty-s-projects.

Deploy the contents of `site/` as the project root (static HTML/JS, no build step, no framework). The current production project is not git-linked; after this repo exists you can connect `hatty-le/eggsy-cx` and set the root directory to `site`.

The frontend talks to `https://xodkbmtylftfmnxfnxxf.supabase.co` with the **public publishable key** (`sb_publishable_…`) already in the pages. Do not put the service role key in the site.

Sign-in: `signInWithOtp` / `verifyOtp` for `@luckyegg.co` addresses. Supabase email templates must include `{{ .Token }}`. Row Level Security is enabled; policies use `public.is_lucky_egg_staff()`.

### Database and functions (Supabase)

Project ref: `xodkbmtylftfmnxfnxxf`.

1. Set the secrets listed below (Dashboard → Edge Functions → Secrets, and Vault where noted).
2. Apply migrations in `supabase/migrations/` in filename order (`supabase db push` or the SQL editor).
3. Deploy each folder under `supabase/functions/` (`supabase functions deploy <name> --no-verify-jwt`). All three live functions have JWT verification off; they authenticate with the staff JWT and/or the Vault hook secret instead.

The last Gmail migrations create `gmail_sync_state`, the Vault secret `eggsy_gmail_push_secret` (random hex, generated at apply time), `cx_gmail_hook_ok`, `cx_gmail_call`, and the two cron jobs. They do not need to be created by hand if you apply those migrations.

## Required secrets (names only)

Never commit values. Never paste them into chat, Slack or email.

### Supabase Edge Function secrets

| Name | Used by |
| --- | --- |
| `SUPABASE_URL` | all three functions (usually provided automatically) |
| `SUPABASE_SERVICE_ROLE_KEY` | all three functions (usually provided automatically) |
| `SUPABASE_ANON_KEY` | `cx-actions` (staff JWT passthrough) |
| `GMAIL_CLIENT_ID` | `send-email-reply`, `gmail-push` |
| `GMAIL_CLIENT_SECRET` | `send-email-reply`, `gmail-push` |
| `GMAIL_REFRESH_TOKEN` | `send-email-reply`, `gmail-push` (hey@ OAuth) |
| `SHOPIFY_ADMIN_ACCESS_TOKEN` | `cx-actions` (Shopify Admin; not required until refunds go live) |
| `SHOPIFY_STORE_DOMAIN` | `cx-actions` |

### Supabase Vault secrets (created by migrations if missing)

| Name | Purpose |
| --- | --- |
| `eggsy_email_hook_secret` | Shared hook header between the database (`cx_email_call`, `cx_actions_call`, `cx_gmail_call`) and the edge functions |
| `eggsy_gmail_push_secret` | Token checked by `cx_gmail_hook_ok` for Gmail Pub/Sub push |
| `shopify_admin_access_token` | Read by `cx_shopify_admin_token()` if/when Shopify refunds are enabled |

`gmail-push` also hard-codes the Pub/Sub topic name it renews the Gmail watch on (`TOPIC_NAME`). That is configuration, not a password; change it in `supabase/functions/gmail-push/index.ts` if the topic changes.

## What not to commit

See `.gitignore`. In particular: `.env*`, `secrets/`, `node_modules/`, `.vercel/`. Do not copy anything from a local `secrets/` directory into this repo.
