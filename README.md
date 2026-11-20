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
  queue/ index.html            send queue
  expired/ index.html          replies the platform can no longer deliver
  sent/ index.html
supabase/
  migrations/                  16 dated SQL migrations (complete)
  functions/
    send-email-reply/          email relay (hey@) for approved replies and bounce sweep
    forward-to-marketing/      staff "Send to marketing" forward from hey@ (does not send to the customer)
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
| `GMAIL_CLIENT_ID` | `send-email-reply`, `forward-to-marketing`, `gmail-push` |
| `GMAIL_CLIENT_SECRET` | `send-email-reply`, `forward-to-marketing`, `gmail-push` |
| `GMAIL_REFRESH_TOKEN` | `send-email-reply`, `forward-to-marketing`, `gmail-push` (hey@ OAuth) |
| `SHOPIFY_ADMIN_ACCESS_TOKEN` | `cx-actions` (Shopify Admin; not required until refunds go live) |
| `SHOPIFY_STORE_DOMAIN` | `cx-actions` |

### Supabase Vault secrets (created by migrations if missing)

| Name | Purpose |
| --- | --- |
| `eggsy_email_hook_secret` | Shared hook header between the database (`cx_email_call`, `cx_actions_call`, `cx_gmail_call`) and the edge functions |
| `eggsy_gmail_push_secret` | Token checked by `cx_gmail_hook_ok` for Gmail Pub/Sub push |
| `shopify_admin_access_token` | Read by `cx_shopify_admin_token()` if/when Shopify refunds are enabled |

`gmail-push` also hard-codes the Pub/Sub topic name it renews the Gmail watch on (`TOPIC_NAME`). That is configuration, not a password; change it in `supabase/functions/gmail-push/index.ts` if the topic changes.

## Orders from Seller Center

TikTok's Open API is not approved, so order details are not fetched from TikTok directly. Eggsy's browser read of the order panel beside a Seller Center chat (and Amazon order details, when those are read the same way) calls `public.cx_upsert_order`. The inbox then shows every linked order on the TikTok and Amazon ticket. If nothing is linked yet, the card says **Order not pulled yet**.

Street addresses, phone numbers, emails and recipient names are not stored. Only city and postcode are kept, and only those are shown.

### Tables

- `public.cx_orders` — one row per marketplace order. Unique on `(origin, platform_order_id)`.
- `public.cx_order_items` — line items for that order (product name, SKU, quantity, price). Replaced whenever the JSON includes an `items` array.
- `public.cx_order_links` — which conversations show the order. One order can be linked to more than one ticket. The link is inserted and left in place on later calls.

RLS is enabled and forced. `@luckyegg.co` staff can select. Writes go through the function, not a direct insert. The function allows staff JWTs and the database roles the importer already uses (`postgres`, `supabase_admin`, `service_role`).

### Function

```text
public.cx_upsert_order(p_conversation_id uuid, p_order jsonb) returns uuid
```

Idempotent on `(origin, platform_order_id)`. A missing `origin` uses the conversation's origin. A later call keeps fields it does not send (null does not wipe a tracking number already stored). Sending `is_sample` always updates that flag. Sending `items` replaces the line items, including with an empty list.

```sql
select public.cx_upsert_order(
  '171cf47e-b3f6-4b15-8356-832172dd9176',
  $order${
    "origin": "tiktok_uk",
    "shop": "TikTok UK",
    "platform_order_id": "576979674268277376",
    "status": "Delivered",
    "ordered_at": "2026-11-10T14:22:00Z",
    "is_sample": true,
    "shipping_status": "Delivered",
    "tracking_number": "EV123456789GB",
    "tracking_carrier": "Evri",
    "tracking_url": null,
    "delivered_at": "2026-11-14T09:05:00Z",
    "recipient_city": "London",
    "recipient_postcode": "E1 6AN",
    "currency": "GBP",
    "source": "tiktok_seller_center",
    "items": [
      {"title": "Snort Funny", "sku": "SNORT-UK", "qty": 1, "price": 0, "currency": "GBP"}
    ]
  }$order$::jsonb
);
```

`order_id` is accepted as an alias of `platform_order_id`. Item `name` or `product` is accepted as `title`. Item `quantity` is accepted as `qty`. `carrier` is accepted as `tracking_carrier`. A nested `recipient` object may supply `city` and `postcode` (or `zip`); any street line in that object is ignored.

`source` is a short label such as `tiktok_seller_center` or `amazon_seller_central`. It is not a secret.

Calling it again with the same origin and order id updates the row and links the new conversation if this ticket was not linked yet.

### Flag replacement

On the order card, **Flag replacement** picks the line items and a reason (missing, damaged, wrong item, never arrived), plus an optional note. It inserts a **pending** `cx_actions` row (`type = replacement`) with `details.flag_reason`, `details.original_order_id`, `details.items`, `details.shop` and `details.fulfilment = amazon_mcf`. It does not send a reply and does not place an order. The row is listed under Actions as "Replacements to place", and on the ticket the existing MCF buttons stay available for whoever processes it.

## What not to commit

See `.gitignore`. In particular: `.env*`, `secrets/`, `node_modules/`, `.vercel/`. Do not copy anything from a local `secrets/` directory into this repo.
