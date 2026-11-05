import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const TOPIC_NAME = "projects/eggsy-cx-513616/topics/gmail-hey-inbox";
const HEY = "hey@luckyegg.co";
const GMAIL_PREFIX = "gmail:";
const WATCH_RENEW_MS = 36 * 60 * 60 * 1000;

const AMAZON_MARKETS: Array<[string, string, string]> = [
  ["marketplace.amazon.com.be", "amazon_be", "Amazon BE"],
  ["marketplace.amazon.co.uk", "amazon_uk", "Amazon UK"],
  ["marketplace.amazon.com", "amazon_us", "Amazon US"],
  ["marketplace.amazon.de", "amazon_de", "Amazon DE"],
  ["marketplace.amazon.fr", "amazon_fr", "Amazon FR"],
  ["marketplace.amazon.it", "amazon_it", "Amazon IT"],
  ["marketplace.amazon.es", "amazon_es", "Amazon ES"],
  ["marketplace.amazon.nl", "amazon_nl", "Amazon NL"],
  ["marketplace.amazon.se", "amazon_se", "Amazon SE"],
  ["marketplace.amazon.pl", "amazon_pl", "Amazon PL"],
  ["marketplace.amazon.ca", "amazon_other", "Amazon CA"],
];

const SKIP_FROM_EXACT = new Set([
  "no-reply@tenevo.co.uk",
  "no-reply@walmart.com",
  "do-not-reply@walmart.com",
  "no-reply@shop.tiktok.com",
  "sellersupport@shop.tiktok.com",
  "uksellersupport@shop.tiktok.com",
  "register@account.tiktok.com",
  "no-reply@shopify.com",
  "support@judge.me",
  "noreply@discord.com",
  "noreply@wise.com",
  "team@sellerboard.com",
  "maccount@microsoft.com",
  "system@thefirstmile.co.uk",
  "operationsteam@eburypartners.com",
  "accounts@vrdistribution.com.au",
  "email@emails.asda.com",
  "wholesale@info.faire.com",
  "noreply@info.faire.com",
]);

const SKIP_FROM_SUFFIX = [
  "@t.shopifyemail.com",
  "@transglobalexpress.co.uk",
  "@info.faire.com",
  "@mail.instagram.com",
  "@stripe.com",
  "@email.apple.com",
  "@notifications.google.com",
];

const SKIP_FROM_INCLUDES = [
  "mailer-daemon@",
  "postmaster@",
  "no-reply@klaviyo.com",
  "donotreply@amazon.",
  "merch.service05@amazon.",
  "order-update@amazon.",
  "seller-notification@amazon.",
  "fba-noreply@amazon.",
  "shipment-tracking@amazon.",
  "sas-enforcement-advisory@amazon.",
  "uk-sfp-performance@amazon.",
  "uk-childrens-sleepwear-safety-mv@amazon.",
  "no-reply@amazon.",
  "e-commerce.ipnotice@mail.byteintl.com",
  "fbt@mail.byteintl.com",
  "no-reply@ads-service.tiktok.com",
  "noreply@business-updates.facebook.com",
  "saferconsumerproducts@",
  "cbsa-asfc@",
  "idg.vendor.compliance@",
  "testflight_no_reply@",
];

const SKIP_SUBJECT = [
  /verification code/i,
  /delivery status notification/i,
  /undelivered mail/i,
  /delivery incomplete/i,
  /your documentation for order/i,
  /chargeback evidence/i,
  /product blocked/i,
  /tiktok shop account new user login/i,
  /you have \d+ chats? to reply/i,
  /return\/refund request received/i,
  /invalid shipping address/i,
  /order #\d+ \(#\d+\) placed/i,
  /amazon hat ihre\(n\) verkauften artikel versandt/i,
  /return authorisation notification/i,
  /verkauft, jetzt liefern/i,
  /^your email to /i,
  /^deine e-mail an /i,
  /instagram recap/i,
  /testflight invitation/i,
  /wise statement/i,
  /\[lucky egg\] order #\d+/i,
];

type Header = { name: string; value: string };
type GmailPayload = {
  mimeType?: string;
  body?: { data?: string };
  parts?: GmailPayload[];
  headers?: Header[];
};
type GmailMessage = {
  id: string;
  threadId: string;
  internalDate?: string;
  labelIds?: string[];
  snippet?: string;
  payload?: GmailPayload;
};

let cachedToken = "";
let cachedTokenExp = 0;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function addrOf(raw: string): string {
  const m = raw.match(/<([^>]+)>/);
  return (m?.[1] || raw).trim().toLowerCase();
}

function nameOf(raw: string): string {
  const m = raw.match(/^\s*"?([^"<]+?)"?\s*<[^>]+>/);
  const name = (m?.[1] || "").trim();
  if (name) return name.replace(/\s+/g, " ");
  const addr = addrOf(raw);
  return addr.includes("@") ? addr.split("@")[0] : raw.trim();
}

function headerValue(headers: Header[] | undefined, name: string): string {
  const n = name.toLowerCase();
  return headers?.find((h) => h.name.toLowerCase() === n)?.value || "";
}

function decodeB64Url(data: string): string {
  try {
    const pad = data.replace(/-/g, "+").replace(/_/g, "/");
    const raw = atob(pad);
    return new TextDecoder().decode(Uint8Array.from(raw, (c) => c.charCodeAt(0)));
  } catch {
    return "";
  }
}

function htmlToText(html: string): string {
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

function extractBody(payload?: GmailPayload): string {
  if (!payload) return "";
  if (payload.body?.data) {
    const decoded = decodeB64Url(payload.body.data);
    return payload.mimeType === "text/html" ? htmlToText(decoded) : decoded;
  }
  const parts = payload.parts || [];
  const plain = parts.find((p) => p.mimeType === "text/plain" && p.body?.data);
  if (plain?.body?.data) return decodeB64Url(plain.body.data);
  const html = parts.find((p) => p.mimeType === "text/html" && p.body?.data);
  if (html?.body?.data) return htmlToText(decodeB64Url(html.body.data));
  for (const part of parts) {
    const inner = extractBody(part);
    if (inner) return inner;
  }
  return "";
}

function parseShopifyForm(body: string, replyTo: string) {
  const name = body.match(/^\s*Name:\s*(.+)$/im)?.[1]?.trim() || "";
  const emailRaw = body.match(/^\s*E-?mail:\s*(.+)$/im)?.[1]?.trim() || replyTo;
  const commentMatch = body.match(/^\s*(?:Comment|Message|Body):\s*([\s\S]+)/im);
  let comment = commentMatch?.[1] || body;
  comment = comment
    .replace(/\nYou received this[\s\S]*$/i, "")
    .replace(/\n--+\s*[\s\S]*$/, "")
    .trim();
  return { name, email: addrOf(emailRaw), comment: comment || body };
}

function shopifyShop(subject: string, body: string): string {
  const text = `${subject}\n${body}`.toLowerCase();
  if (/murder mystery|murdermysterycases/.test(text)) return "Murder Mystery Cases (GB)";
  const shopName = subject.match(/^New customer message on\s+(.+)$/i)?.[1] || "";
  if (/ireland|\(ie\)|\bie\b/i.test(shopName) || /luckyegg \(ie\)|lucky egg \(ie\)/.test(text)) {
    return "Lucky Egg (IE)";
  }
  if (/united states|\(us\)|\bus\b/i.test(shopName) || /luckyegg \(us\)|lucky egg \(us\)/.test(text)) {
    return "Lucky Egg (US)";
  }
  return "Lucky Egg (GB)";
}

function emailShop(subject: string, body: string): string {
  if (/murder mystery|murdermysterycases|death at area|death of an influencer|dublin castle|buckingham palace|eiffel tower/i.test(`${subject}\n${body}`)) {
    return "Murder Mystery Cases";
  }
  return "Lucky Egg";
}

function matchAmazon(text: string) {
  const lower = text.toLowerCase();
  for (const [host, origin, shop] of AMAZON_MARKETS) {
    if (lower.includes(host)) return { origin, shop };
  }
  return null;
}

function extractOrderNumber(subject: string, body: string): string | null {
  const amazon = `${subject}\n${body}`.match(/\b(\d{3}-\d{7}-\d{7})\b/);
  if (amazon) return amazon[1];
  const shopify = `${subject}\n${body}`.match(/\b(?:order(?:\s+number)?\s*[:#]?\s*|#)(\d{4,7})\b/i);
  if (shopify) return shopify[1];
  const tiktok = `${subject}\n${body}`.match(/\b(57\d{16,})\b/);
  if (tiktok) return tiktok[1];
  return null;
}

function isAutomated(fromA: string, subject: string): boolean {
  if (SKIP_FROM_EXACT.has(fromA)) return true;
  if (SKIP_FROM_SUFFIX.some((s) => fromA.endsWith(s))) return true;
  if (SKIP_FROM_INCLUDES.some((s) => fromA.includes(s))) return true;
  if (fromA.endsWith("@s.urbnvendor.com") || fromA.includes("urbnvendorrelations@")) return true;
  return SKIP_SUBJECT.some((re) => re.test(subject));
}

const TOPIC_VALUES = [
  "Return request",
  "Refund request",
  "Shipping / where's my order",
  "Damaged or faulty",
  "Missing parts",
  "Replacement",
  "Product / gameplay question",
  "Order change / cancellation",
  "Address issue",
  "Wholesale / B2B",
  "Complaint",
  "Feedback / praise",
  "Other",
];

function inferTopic(subject: string, body: string): string | null {
  const t = `${subject}
${body}`.toLowerCase();
  if (/replacement/.test(t)) return "Replacement";
  if (/refund/.test(t)) return "Refund request";
  if (/return(?:s|ing|ed)?/.test(t) && !/returned mail|undeliverable/.test(t)) return "Return request";
  if (/missing (?:part|parts|piece|pieces|item|items)/.test(t)) return "Missing parts";
  if (/(?:damaged|faulty|broken|not working|doesn't work|does not work)/.test(t)) return "Damaged or faulty";
  if (/where(?:'s| is) my (?:order|parcel|package)|tracking/.test(t)) return "Shipping / where's my order";
  if (/cancel/.test(t) || /change (?:my )?(?:address|order)/.test(t)) return "Order change / cancellation";
  if (/wholesale|b2b/.test(t)) return "Wholesale / B2B";
  return null;
}

function classify(msg: GmailMessage, from: string, replyTo: string, subject: string, body: string) {
  const fromA = addrOf(from);
  if (fromA === HEY) return { kind: "outgoing" as const };

  const hay = `${from} ${replyTo} ${subject}`;
  const amazon = matchAmazon(hay);
  if (amazon) {
    return { kind: "ingest" as const, origin: amazon.origin, shop: amazon.shop };
  }

  if (
    fromA === "mailer@shopify.com" ||
    /via shopify contact form/i.test(from) ||
    /^contact form:/i.test(subject) ||
    /^new customer message on /i.test(subject)
  ) {
    return { kind: "ingest" as const, origin: "shopify_form", shop: shopifyShop(subject, body) };
  }

  if (
    /@wix\.com$/i.test(fromA) ||
    /murdermysterycases/i.test(fromA) ||
    /you received a new message from .{0,120}wix/i.test(body)
  ) {
    return { kind: "ingest" as const, origin: "wix_mmc_form", shop: "Murder Mystery Cases (Wix form)" };
  }

  if (/message from walmart\.com customer/i.test(subject) || /marketplace\.walmart/i.test(hay)) {
    return { kind: "ingest" as const, origin: "walmart", shop: "Walmart US" };
  }

  const tiktokBuyer = /tiktok/i.test(hay) &&
    /(?:buyer|customer)\s+message|new message from .{0,60}customer/i.test(`${subject}\n${body}`) &&
    !isAutomated(fromA, subject);
  if (tiktokBuyer) {
    const origin = /@.*uk|tiktok uk|\.co\.uk/i.test(hay) ? "tiktok_uk" : /eu|europe/i.test(hay) ? "tiktok_eu" : "tiktok_us";
    const shop = origin === "tiktok_uk" ? "TikTok UK" : origin === "tiktok_eu" ? "TikTok EU" : "TikTok US";
    return { kind: "ingest" as const, origin, shop };
  }

  if (isAutomated(fromA, subject)) return { kind: "skip" as const, reason: "automated" };
  return { kind: "ingest" as const, origin: "email_hey", shop: emailShop(subject, body) };
}

async function gmailToken(): Promise<string> {
  if (cachedToken && Date.now() < cachedTokenExp - 30_000) return cachedToken;
  const clientId = Deno.env.get("GMAIL_CLIENT_ID") || "";
  const clientSecret = Deno.env.get("GMAIL_CLIENT_SECRET") || "";
  const refreshToken = Deno.env.get("GMAIL_REFRESH_TOKEN") || "";
  if (!clientId || !clientSecret || !refreshToken) {
    throw new Error("Missing GMAIL_CLIENT_ID, GMAIL_CLIENT_SECRET or GMAIL_REFRESH_TOKEN");
  }
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });
  const data = await res.json();
  if (!res.ok || !data.access_token) {
    throw new Error(`Gmail token refresh failed (${res.status})`);
  }
  cachedToken = data.access_token as string;
  cachedTokenExp = Date.now() + Number(data.expires_in || 3600) * 1000;
  return cachedToken;
}

async function gmailFetch(path: string, init: RequestInit = {}) {
  const token = await gmailToken();
  const res = await fetch(`https://gmail.googleapis.com/gmail/v1/users/me/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  let data: any = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { raw: text };
  }
  if (!res.ok) {
    const detail = data?.error?.message || data?.error || "";
    const err = new Error(`Gmail ${path.split("?")[0]} failed (${res.status}${detail ? `: ${detail}` : ""})`) as Error & { status?: number; body?: unknown };
    err.status = res.status;
    err.body = data;
    throw err;
  }
  return data;
}

async function gmailFetchRetry(path: string, init: RequestInit = {}, attempts = 5) {
  let last: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await gmailFetch(path, init);
    } catch (e) {
      last = e;
      const status = (e as { status?: number }).status;
      if (status === 403 || status === 429 || status === 503) {
        await new Promise((r) => setTimeout(r, 400 * (2 ** i)));
        continue;
      }
      throw e;
    }
  }
  throw last;
}

function sbAdmin(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL") || "";
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  return createClient(url, key, { auth: { persistSession: false } });
}

async function authorized(req: Request, sb: SupabaseClient): Promise<boolean> {
  const url = new URL(req.url);
  const token = url.searchParams.get("token") || req.headers.get("x-eggsy-gmail-push") || "";
  if (token) {
    const { data } = await sb.rpc("cx_gmail_hook_ok", { p_secret: token });
    if (data === true) return true;
  }
  const hook = req.headers.get("x-eggsy-hook") || "";
  if (hook) {
    const { data } = await sb.rpc("cx_email_hook_ok", { p_secret: hook });
    if (data === true) return true;
  }
  return false;
}

async function getState(sb: SupabaseClient) {
  const { data, error } = await sb.from("gmail_sync_state").select("*").eq("id", 1).maybeSingle();
  if (error) throw error;
  return data as {
    history_id: string | null;
    watch_expiration: string | null;
    watch_topic: string | null;
  } | null;
}

async function saveState(sb: SupabaseClient, patch: Record<string, unknown>) {
  const { error } = await sb.from("gmail_sync_state").update({
    ...patch,
    updated_at: new Date().toISOString(),
  }).eq("id", 1);
  if (error) throw error;
}

async function profileHistoryId(): Promise<string> {
  const profile = await gmailFetch("profile");
  return String(profile.historyId);
}

async function renewWatch(): Promise<{ historyId: string; expiration: string | null; error?: string }> {
  try {
    const data = await gmailFetch("watch", {
      method: "POST",
      body: JSON.stringify({ topicName: TOPIC_NAME, labelIds: ["INBOX"] }),
    });
    return {
      historyId: String(data.historyId),
      expiration: data.expiration ? new Date(Number(data.expiration)).toISOString() : null,
    };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { historyId: "", expiration: null, error: msg };
  }
}

async function listMessageIdsSince(afterIso: string): Promise<string[]> {
  const afterMs = Date.parse(afterIso);
  const afterQuery = `after:${Math.floor(afterMs / 1000)}`;
  const ids: string[] = [];
  let pageToken = "";
  do {
    const params = new URLSearchParams({ q: afterQuery, maxResults: "100" });
    if (pageToken) params.set("pageToken", pageToken);
    const data = await gmailFetch(`messages?${params}`);
    for (const m of data.messages || []) ids.push(m.id);
    pageToken = data.nextPageToken || "";
  } while (pageToken);
  return ids;
}

async function listMessageIdsFromHistory(startHistoryId: string): Promise<{ ids: string[]; newHistoryId: string; stale?: boolean }> {
  const ids = new Set<string>();
  let pageToken = "";
  let newHistoryId = startHistoryId;
  try {
    do {
      const params = new URLSearchParams({
        startHistoryId,
        maxResults: "500",
      });
      if (pageToken) params.set("pageToken", pageToken);
      const data = await gmailFetch(`history?${params}`);
      newHistoryId = String(data.historyId || newHistoryId);
      for (const h of data.history || []) {
        for (const added of h.messagesAdded || []) {
          if (added.message?.id) ids.add(added.message.id);
        }
      }
      pageToken = data.nextPageToken || "";
    } while (pageToken);
    return { ids: [...ids], newHistoryId };
  } catch (e) {
    const status = (e as { status?: number }).status;
    if (status === 404) return { ids: [], newHistoryId: startHistoryId, stale: true };
    throw e;
  }
}

async function findExistingMessage(sb: SupabaseClient, messageId: string) {
  const { data } = await sb
    .from("messages")
    .select("id, conversation_id")
    .eq("external_id", `${GMAIL_PREFIX}${messageId}`)
    .maybeSingle();
  return data;
}

async function findConversation(
  sb: SupabaseClient,
  origin: string,
  threadId: string,
  orderNumber: string | null,
) {
  const { data: byThread } = await sb
    .from("conversations")
    .select("id, status, customer_handle, order_number, subject")
    .eq("external_id", `${GMAIL_PREFIX}${threadId}`)
    .maybeSingle();
  if (byThread) return byThread;

  const { data: byMsgThread } = await sb
    .from("messages")
    .select("conversation_id")
    .eq("external_thread_id", threadId)
    .limit(1)
    .maybeSingle();
  if (byMsgThread?.conversation_id) {
    const { data } = await sb
      .from("conversations")
      .select("id, status, customer_handle, order_number, subject")
      .eq("id", byMsgThread.conversation_id)
      .maybeSingle();
    if (data) return data;
  }

  if (orderNumber && /^[0-9-]+$/.test(orderNumber) && origin.startsWith("amazon")) {
    const { data: byExt } = await sb
      .from("conversations")
      .select("id, status, customer_handle, order_number, subject")
      .eq("origin", origin)
      .eq("external_id", `amazon:${orderNumber}`)
      .maybeSingle();
    if (byExt) return byExt;
    const { data: byOrder } = await sb
      .from("conversations")
      .select("id, status, customer_handle, order_number, subject")
      .eq("origin", origin)
      .eq("order_number", orderNumber)
      .limit(1)
      .maybeSingle();
    if (byOrder) return byOrder;
  }
  return null;
}

async function ingestMessage(sb: SupabaseClient, msg: GmailMessage, afterMs?: number) {
  const sentAtMs = Number(msg.internalDate || 0);
  if (afterMs && sentAtMs && sentAtMs < afterMs) return { action: "skipped", reason: "before_cutoff" };

  const existing = await findExistingMessage(sb, msg.id);
  if (existing) return { action: "skipped", reason: "duplicate" };

  const from = headerValue(msg.payload?.headers, "From");
  const replyTo = headerValue(msg.payload?.headers, "Reply-To");
  const subject = headerValue(msg.payload?.headers, "Subject") || "(no subject)";
  const rawBody = extractBody(msg.payload);
  const body = rawBody.replace(/\r\n/g, "\n").trim() || msg.snippet || "";
  const sentAt = sentAtMs ? new Date(sentAtMs).toISOString() : new Date().toISOString();
  const classified = classify(msg, from, replyTo, subject, body);

  if (classified.kind === "skip") return { action: "skipped", reason: classified.reason };

  if (classified.kind === "outgoing") {
    const conv = await findConversation(sb, "email_hey", msg.threadId, extractOrderNumber(subject, body));
    if (!conv) return { action: "skipped", reason: "outgoing_no_ticket" };
    const { error } = await sb.from("messages").insert({
      conversation_id: conv.id,
      direction: "outbound",
      author: "Lucky Egg (hey@)",
      body,
      sent_at: sentAt,
      external_id: `${GMAIL_PREFIX}${msg.id}`,
      external_thread_id: msg.threadId,
    });
    if (error) {
      if (String(error.message || "").toLowerCase().includes("duplicate")) {
        return { action: "skipped", reason: "duplicate" };
      }
      throw error;
    }
    await sb.from("conversations").update({
      last_message_at: sentAt,
      updated_at: new Date().toISOString(),
    }).eq("id", conv.id);
    return { action: "logged_outgoing", conversation_id: conv.id };
  }

  let customerName = nameOf(from);
  let customerHandle = addrOf(from);
  let storedBody = body;
  if (classified.origin === "shopify_form") {
    const parsed = parseShopifyForm(body, replyTo);
    if (parsed.name) customerName = parsed.name;
    if (parsed.email) customerHandle = parsed.email;
    storedBody = parsed.comment;
  } else if (replyTo && addrOf(replyTo) && addrOf(replyTo) !== addrOf(from) && !addrOf(from).includes("marketplace.amazon.")) {
    // Prefer a real customer reply-to when the visible From is a mailer.
    if (from.toLowerCase().includes("mailer") || from.toLowerCase().includes("no-reply") || from.toLowerCase().includes("via ")) {
      customerHandle = addrOf(replyTo);
    }
  }

  const orderNumber = extractOrderNumber(subject, storedBody);
  let conv = await findConversation(sb, classified.origin, msg.threadId, orderNumber);
  const now = new Date().toISOString();

  if (!conv) {
    const insert = {
      origin: classified.origin,
      shop: classified.shop,
      customer_name: customerName || customerHandle,
      customer_handle: customerHandle,
      subject,
      order_number: orderNumber,
      status: "open",
      external_id: `${GMAIL_PREFIX}${msg.threadId}`,
      last_message_at: sentAt,
      topic: inferTopic(subject, storedBody),
      created_at: now,
      updated_at: now,
    };
    const { data, error } = await sb.from("conversations").insert(insert).select("id, status, customer_handle, order_number, subject").maybeSingle();
    if (error) {
      const again = await findConversation(sb, classified.origin, msg.threadId, orderNumber);
      if (!again) throw error;
      conv = again;
    } else {
      conv = data!;
    }
  }

  const { error: msgErr } = await sb.from("messages").insert({
    conversation_id: conv.id,
    direction: "inbound",
    author: customerName || customerHandle,
    body: storedBody,
    sent_at: sentAt,
    external_id: `${GMAIL_PREFIX}${msg.id}`,
    external_thread_id: msg.threadId,
  });
  if (msgErr) {
    if (String(msgErr.message || "").toLowerCase().includes("duplicate")) {
      return { action: "skipped", reason: "duplicate" };
    }
    throw msgErr;
  }

  const reopen = conv.status === "awaiting_customer" || conv.status === "resolved";
  const updates: Record<string, unknown> = {
    last_message_at: sentAt,
    updated_at: now,
  };
  if (reopen) {
    updates.status = "open";
    updates.status_changed_at = now;
  }
  if (!conv.customer_handle && customerHandle) updates.customer_handle = customerHandle;
  if (!conv.order_number && orderNumber) updates.order_number = orderNumber;
  if (!conv.subject && subject) updates.subject = subject;
  await sb.from("conversations").update(updates).eq("id", conv.id);
  return { action: "ingested", conversation_id: conv.id, reopened: reopen };
}

async function processIds(sb: SupabaseClient, ids: string[], afterMs?: number) {
  const counts = { ingested: 0, skipped: 0, logged_outgoing: 0, errors: 0 };
  const ingested: string[] = [];
  for (const id of ids) {
    try {
      const meta = await gmailFetchRetry(
        `messages/${id}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Reply-To`,
      ) as GmailMessage;
      const sentAtMs = Number(meta.internalDate || 0);
      if (afterMs && sentAtMs && sentAtMs < afterMs) {
        counts.skipped += 1;
        continue;
      }
      const from = headerValue(meta.payload?.headers, "From");
      const replyTo = headerValue(meta.payload?.headers, "Reply-To");
      const subject = headerValue(meta.payload?.headers, "Subject") || "(no subject)";
      const pre = classify(meta, from, replyTo, subject, meta.snippet || "");
      if (pre.kind === "skip") {
        counts.skipped += 1;
        continue;
      }
      const msg = await gmailFetchRetry(`messages/${id}?format=full`) as GmailMessage;
      const result = await ingestMessage(sb, msg, afterMs);
      if (result.action === "ingested") {
        counts.ingested += 1;
        if (result.conversation_id) ingested.push(result.conversation_id);
      } else if (result.action === "logged_outgoing") {
        counts.logged_outgoing += 1;
      } else {
        counts.skipped += 1;
      }
    } catch (e) {
      counts.errors += 1;
      console.error("gmail-push ingest failed", id, e instanceof Error ? e.message : e);
    }
  }
  return { ...counts, conversation_ids: [...new Set(ingested)] };
}

async function maybeRenewWatch(sb: SupabaseClient, force = false) {
  const state = await getState(sb);
  const exp = state?.watch_expiration ? Date.parse(state.watch_expiration) : 0;
  if (!force && exp && exp - Date.now() > WATCH_RENEW_MS) {
    return { renewed: false, expiration: state?.watch_expiration, error: null as string | null };
  }
  const watch = await renewWatch();
  if (watch.error) {
    const prev = await getState(sb);
    await saveState(sb, { last_error: [ (prev as any)?.last_error, `watch: ${watch.error}` ].filter(Boolean).join("; ") });
    return { renewed: false, expiration: state?.watch_expiration || null, error: watch.error };
  }
  const patch: Record<string, unknown> = {
    watch_expiration: watch.expiration,
    watch_topic: TOPIC_NAME,
    last_error: null,
  };
  if (watch.historyId && !state?.history_id) patch.history_id = watch.historyId;
  await saveState(sb, patch);
  return { renewed: true, expiration: watch.expiration, error: null as string | null };
}

async function runSync(sb: SupabaseClient, opts: { after?: string; watch?: boolean }) {
  const afterMs = opts.after ? Date.parse(opts.after) : undefined;
  let ids: string[] = [];
  const state = await getState(sb);
  let nextHistoryId = state?.history_id || "";

  if (opts.after) {
    ids = await listMessageIdsSince(opts.after);
    nextHistoryId = await profileHistoryId();
  } else if (state?.history_id) {
    const hist = await listMessageIdsFromHistory(state.history_id);
    if (hist.stale) {
      const fallbackAfter = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString();
      ids = await listMessageIdsSince(fallbackAfter);
      nextHistoryId = await profileHistoryId();
    } else {
      ids = hist.ids;
      nextHistoryId = hist.newHistoryId;
    }
  } else {
    nextHistoryId = await profileHistoryId();
  }

  const processed = await processIds(sb, ids, afterMs);
  await saveState(sb, {
    history_id: nextHistoryId,
    last_synced_at: new Date().toISOString(),
    last_result: processed,
    last_error: processed.errors ? `${processed.errors} message errors` : null,
  });

  let watch: { renewed: boolean; expiration: string | null; error: string | null } | undefined;
  if (opts.watch !== false) {
    watch = await maybeRenewWatch(sb, opts.watch === true);
  }
  return { ...processed, history_id: nextHistoryId, watch };
}

Deno.serve(async (req: Request) => {
  if (req.method === "GET") {
    return json({ ok: true, service: "gmail-push" });
  }
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const sb = sbAdmin();
  if (!(await authorized(req, sb))) return json({ error: "unauthorized" }, 401);

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  const isPubSub = Boolean(body?.message?.data || body?.message?.messageId);
  const mode = isPubSub ? "sync" : (body.mode || "sync");

  try {
    if (mode === "watch") {
      const watch = await maybeRenewWatch(sb, true);
      return json({ ok: !watch.error, mode, watch });
    }
    const after = mode === "backfill" ? (body.after || "2026-11-05T11:15:00Z") : body.after;
    const result = await runSync(sb, { after, watch: mode !== "backfill" || body.watch === true });
    return json({ ok: true, mode, ...result });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("gmail-push failed", message);
    try {
      await saveState(sb, { last_error: message, last_synced_at: new Date().toISOString() });
    } catch {
      // ignore state write failures
    }
    return json({ ok: false, error: message }, 500);
  }
});
