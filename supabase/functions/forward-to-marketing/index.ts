// forward-to-marketing: staff send a ticket to marketing from hey@luckyegg.co.
// Email tickets are a Gmail forward (original sender, date, subject, full body, attachments from the Gmail API).
// Other channels (TikTok, Amazon, Meta, Walmart, ...) send the conversation transcript instead.
// Nothing is written to reply_queue and nothing is sent to the customer.
// A successful forward also drafts a holding reply (cx_place_holding_reply). That stays a draft.
// Gmail send uses the same quota wait-and-retry as send-email-reply (429 / rateLimitExceeded / quota exceeded).
// The HTML + plain text part uses the same multipart/alternative envelope as that sender.
// Recipient: cx_settings key marketing_forward_to (default will.h@luckyegg.co, @luckyegg.co only).
// Format tests (mode "format-test", hook secret only) go to hey@luckyegg.co and do not change the ticket.
// Never logs email bodies or secrets.
import { createClient } from "npm:@supabase/supabase-js@2";
import { b64, mimeAlternative } from "./format.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SB = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const G = "https://gmail.googleapis.com/gmail/v1/users/me/";
const FROM = "hey@luckyegg.co";
const DEFAULT_TO = "will.h@luckyegg.co";
const TEST_TO = "hey@luckyegg.co";
const TICKET_ORIGIN = "https://eggsy-cx.vercel.app";
const EMAIL_ORIGINS = new Set(["email_hey", "shopify_form", "wix_mmc_form"]);
const PENDING = "note:marketing-forward:pending";
const MAX_ATTACH = 20 * 1024 * 1024;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-eggsy-hook",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// Draft only. Never throws: a forward that already reached the colleague still succeeds.
async function placeHoldingReply(cid: string) {
  try {
    const { data, error } = await SB.rpc("cx_place_holding_reply", { p_conversation: cid, p_replace: false });
    if (error) {
      console.error("holding reply: " + String(error.message || "").slice(0, 160));
      return { ok: false };
    }
    return data;
  } catch (e) {
    console.error("holding reply: " + String((e as Error).message || e).slice(0, 160));
    return { ok: false };
  }
}

let tok: string | null = null;
async function token() {
  if (tok) return tok;
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      client_id: Deno.env.get("GMAIL_CLIENT_ID")!,
      client_secret: Deno.env.get("GMAIL_CLIENT_SECRET")!,
      refresh_token: Deno.env.get("GMAIL_REFRESH_TOKEN")!,
    }),
  });
  const j = await r.json();
  if (!r.ok || !j.access_token) throw new Error("Gmail sign-in failed (" + r.status + ")");
  return (tok = j.access_token);
}
async function gm(path: string, body?: unknown, method?: string) {
  const r = await fetch(G + path, {
    method: method || (body ? "POST" : "GET"),
    headers: { Authorization: "Bearer " + await token(), "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await r.text();
  let j: any = {};
  try { j = t ? JSON.parse(t) : {}; } catch { /* */ }
  if (!r.ok) {
    const e: any = new Error("Gmail " + r.status + ": " + (j?.error?.message || "error").slice(0, 200));
    e.status = r.status;
    e.reason = String(j?.error?.errors?.[0]?.reason || j?.error?.status || "");
    e.gmsg = String(j?.error?.message || "");
    throw e;
  }
  return j;
}
const sleep = (ms: number) => new Promise((res) => setTimeout(res, ms));
// Same rule as send-email-reply: a rate limit or quota error means Gmail did not act, so wait and try again.
function isRateLimited(e: any): boolean {
  const st = e?.status || 0;
  if (st === 429) return true;
  if (st !== 403) return false;
  return /rateLimitExceeded|userRateLimitExceeded|quotaExceeded|RESOURCE_EXHAUSTED/i.test(e?.reason || "") || /quota exceeded|rate limit/i.test(e?.gmsg || "");
}
const BACKOFF_MS = [1000, 2000, 4000, 8000];
async function gmRetry(path: string, body?: unknown, method?: string) {
  for (let i = 0; ; i++) {
    try { return await gm(path, body, method); }
    catch (e) {
      if (!isRateLimited(e) || i >= BACKOFF_MS.length) throw e;
      const wait = BACKOFF_MS[i] + Math.floor(Math.random() * BACKOFF_MS[i]);
      console.warn("Gmail rate limit (" + (e as any).status + " " + ((e as any).reason || "") + ") on " + path.split("?")[0].split("/")[0] + "; retry " + (i + 1) + " in " + wait + " ms");
      await sleep(wait);
    }
  }
}

const hdr = (m: any, n: string) => (m?.payload?.headers || []).find((h: any) => h.name.toLowerCase() === n.toLowerCase())?.value || "";
const partHdr = (p: any, n: string) => (p?.headers || []).find((h: any) => h.name.toLowerCase() === n.toLowerCase())?.value || "";
const enc = new TextEncoder();
const clean = (s: string) => String(s || "").replace(/[\r\n]+/g, " ").trim();
function encWord(s: string) {
  if (/^[\x20-\x7e]*$/.test(s)) return s;
  const out: string[] = [];
  let cur = "";
  for (const ch of s) {
    if (enc.encode(cur + ch).length > 42) { out.push(cur); cur = ""; }
    cur += ch;
  }
  if (cur) out.push(cur);
  return out.map((p) => "=?UTF-8?B?" + b64(enc.encode(p)) + "?=").join("\r\n ");
}
function fromB64Url(d: string): Uint8Array {
  const s = atob(String(d || "").replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}
function b64LinesU8(u8: Uint8Array) {
  return b64(u8).replace(/.{1,76}/g, "$&\r\n");
}
function decodeText(d: string): string {
  try { return new TextDecoder().decode(fromB64Url(d)); } catch { return ""; }
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
function textOf(p: any): string {
  if (!p) return "";
  if (!p.filename && p.mimeType === "text/plain" && p.body?.data) return decodeText(p.body.data);
  let s = "";
  for (const c of p.parts || []) {
    const t = textOf(c);
    if (t) s += (s ? "\n" : "") + t;
  }
  if (s.trim()) return s;
  if (!p.filename && p.mimeType === "text/html" && p.body?.data) return htmlToText(decodeText(p.body.data));
  return "";
}
function safeName(s: string) {
  const t = String(s || "").replace(/[\r\n"]/g, "").replace(/[^\w.\- ()[\]]+/g, "_").slice(0, 120).trim();
  return t || "attachment";
}
function fwdSubject(original: string) {
  const t = clean(original) || "(no subject)";
  return /^fwd:/i.test(t) ? t : "Fwd: " + t;
}
function ukStamp(d: Date = new Date()) {
  return d.toLocaleString("en-GB", { timeZone: "Europe/London", day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
}
function lucky(addr: string) {
  const t = String(addr || "").trim().toLowerCase();
  return /^[^@\s]+@luckyegg\.co$/.test(t) ? t : "";
}
async function marketingTo(): Promise<string> {
  const { data } = await SB.from("cx_settings").select("value").eq("key", "marketing_forward_to").maybeSingle();
  const v = data?.value;
  const s = typeof v === "string" ? v : (v && typeof v.email === "string" ? v.email : "");
  return lucky(s) || DEFAULT_TO;
}

type Att = { filename: string; mime: string; bytes: Uint8Array };
function collectParts(p: any, out: any[]) {
  if (!p) return;
  const name = String(p.filename || "").trim();
  const disp = partHdr(p, "Content-Disposition");
  const isFile = !!name || /^attachment/i.test(disp);
  if (isFile && !String(p.mimeType || "").startsWith("multipart/") && (p.body?.attachmentId || p.body?.data)) out.push(p);
  for (const c of p.parts || []) collectParts(c, out);
}
async function loadAttachments(messageId: string, payload: any): Promise<{ atts: Att[]; skipped: string[] }> {
  const parts: any[] = [];
  collectParts(payload, parts);
  const atts: Att[] = [];
  const skipped: string[] = [];
  const used = new Set<string>();
  let total = 0;
  for (const p of parts) {
    let filename = safeName(p.filename || "attachment");
    if (used.has(filename.toLowerCase())) {
      const dot = filename.lastIndexOf(".");
      const stem = dot > 0 ? filename.slice(0, dot) : filename;
      const ext = dot > 0 ? filename.slice(dot) : "";
      let n = 2;
      while (used.has((stem + "-" + n + ext).toLowerCase())) n++;
      filename = stem + "-" + n + ext;
    }
    used.add(filename.toLowerCase());
    try {
      let bytes: Uint8Array | null = null;
      if (p.body?.data) bytes = fromB64Url(p.body.data);
      else if (p.body?.attachmentId) {
        const j = await gmRetry("messages/" + messageId + "/attachments/" + encodeURIComponent(p.body.attachmentId));
        bytes = j?.data ? fromB64Url(j.data) : null;
      }
      if (!bytes?.length) { skipped.push(filename + " (empty)"); continue; }
      if (total + bytes.length > MAX_ATTACH) { skipped.push(filename + " (too large to include)"); continue; }
      total += bytes.length;
      atts.push({ filename, mime: clean(p.mimeType || "application/octet-stream") || "application/octet-stream", bytes });
    } catch (e) {
      if (isRateLimited(e)) throw e;
      skipped.push(filename + " (could not be fetched)");
    }
  }
  return { atts, skipped };
}

async function resolveGmail(mid: string, row: any, email: string) {
  try { return await gmRetry("messages/" + mid + "?format=full"); }
  catch (e) { if (![400, 404].includes((e as any).status)) throw e; }
  if (!email.includes("@") || !row?.sent_at) return null;
  const t = Math.floor(Date.parse(row.sent_at) / 1000);
  if (!t) return null;
  const list = await gmRetry("messages?" + new URLSearchParams({
    q: 'from:"' + email.replace(/"/g, "") + '" after:' + (t - 7200) + " before:" + (t + 7200),
    maxResults: "5",
    includeSpamTrash: "true",
  }));
  const it = (list.messages || [])[0];
  return it ? await gmRetry("messages/" + it.id + "?format=full") : null;
}

function headerLine(by: string, cid: string) {
  return "Forwarded from Eggsy CX by " + by + ". Ticket: " + TICKET_ORIGIN + "/inbox/?c=" + cid;
}

async function composeEmail(conv: any, rows: any[], by: string) {
  const handle = String(conv.customer_handle || "").trim().toLowerCase();
  const gmailRows = (rows || []).filter((r) => r.direction === "inbound" && String(r.external_id || "").startsWith("gmail:"));
  // Newest message is the body. Attachments are taken from every inbound email on the ticket
  // that is still in hey@, so a photo sent earlier in the thread is included.
  const resolved: any[] = [];
  for (const r of [...gmailRows].reverse()) {
    const msg = await resolveGmail(String(r.external_id).slice(6), r, handle);
    if (msg) resolved.push(msg);
    if (resolved.length >= 5) break;
  }
  if (!resolved.length) return null;
  const orig = resolved[0];
  const from = clean(hdr(orig, "From")) || [conv.customer_name, handle].filter(Boolean).join(" ");
  const date = clean(hdr(orig, "Date")) || (orig.internalDate ? new Date(Number(orig.internalDate)).toUTCString() : "");
  const subject = clean(hdr(orig, "Subject")) || clean(conv.subject) || "(no subject)";
  const to = clean(hdr(orig, "To"));
  let body = textOf(orig.payload).replace(/\u0000/g, "").trim();
  if (!body) {
    const stored = [...gmailRows].reverse().map((r) => String(r.body || "").trim()).find(Boolean) || "";
    body = stored;
  }
  if (body.length > 200000) body = body.slice(0, 200000) + "\n\n[truncated]";
  const atts: Att[] = [];
  const skipped: string[] = [];
  const seen = new Set<string>();
  for (const msg of resolved) {
    const got = await loadAttachments(msg.id, msg.payload);
    for (const a of got.atts) {
      const key = a.filename.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      atts.push(a);
    }
    skipped.push(...got.skipped);
  }
  const lines = [headerLine(by, conv.id), "", "From: " + from, "Date: " + (date || "unknown"), "Subject: " + subject];
  if (to) lines.push("To: " + to);
  lines.push("", body || "(no message body)");
  if (skipped.length) {
    lines.push("", "Some attachments could not be included:");
    for (const s of skipped) lines.push("- " + s);
  }
  return {
    kind: "email" as const,
    subject: fwdSubject(subject),
    plain: lines.join("\n"),
    atts,
    skipped,
    original_chars: body.length,
  };
}

function composeTranscript(conv: any, rows: any[], by: string, intro?: string) {
  const msgs = (rows || []).filter((m) => (m.direction === "inbound" || m.direction === "outbound") && String(m.body || "").trim() && !/^\[Summary by Eggsy/.test(m.body || ""));
  const lines = [headerLine(by, conv.id), "", intro || "This is not an email, so the conversation transcript is below.", "Channel: " + (conv.origin || "")];
  const who = [conv.customer_name, conv.customer_handle].filter(Boolean).join(" · ");
  if (who) lines.push("Customer: " + who);
  if (conv.order_number) lines.push("Order: " + conv.order_number);
  const subject = clean(conv.subject) || clean(conv.overview) || clean((conv.customer_name || "Customer") + " via " + (conv.origin || "Eggsy CX"));
  lines.push("Subject: " + subject, "");
  if (!msgs.length) lines.push("(no messages stored)");
  for (const m of msgs) {
    const role = m.direction === "inbound" ? "Customer" : "Lucky Egg";
    const name = m.author || (m.direction === "inbound" ? (conv.customer_name || "Customer") : "Lucky Egg");
    lines.push("[" + ukStamp(new Date(m.sent_at)) + " UK] " + role + " · " + name);
    const text = String(m.body || "").trim();
    lines.push(text.length > 20000 ? text.slice(0, 20000) + "\n[truncated]" : text, "");
  }
  const plain = lines.join("\n").trim();
  return { kind: "transcript" as const, subject: fwdSubject(subject), plain, atts: [] as Att[], skipped: [] as string[], original_chars: plain.length };
}

function buildRaw(to: string, subject: string, plain: string, atts: Att[]) {
  const alt = mimeAlternative(plain);
  const head = ["From: Lucky Egg <" + FROM + ">", "To: " + clean(to), "Subject: " + encWord(clean(subject)), "MIME-Version: 1.0"];
  let lines: string[];
  if (!atts.length) lines = [...head, ...alt];
  else {
    const boundary = "eggsy_mix_" + crypto.randomUUID().replace(/-/g, "");
    lines = [...head, 'Content-Type: multipart/mixed; boundary="' + boundary + '"', "", "--" + boundary, ...alt];
    for (const a of atts) {
      lines.push(
        "--" + boundary,
        'Content-Type: ' + a.mime + '; name="' + a.filename + '"',
        'Content-Disposition: attachment; filename="' + a.filename + '"',
        "Content-Transfer-Encoding: base64",
        "",
        b64LinesU8(a.bytes),
      );
    }
    lines.push("--" + boundary + "--", "");
  }
  return b64(enc.encode(lines.join("\r\n"))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function checksFor(kind: string, plain: string, subject: string, by: string, cid: string) {
  return {
    header: plain.startsWith("Forwarded from Eggsy CX by " + by),
    ticket: plain.includes(TICKET_ORIGIN + "/inbox/?c=" + cid),
    from: kind === "transcript" || /^From: /m.test(plain),
    date: kind === "transcript" || /^Date: /m.test(plain),
    subject_line: /^Subject: /m.test(plain),
    fwd_subject: /^fwd:/i.test(subject),
  };
}

async function confirmSent(id: string) {
  const m = await gmRetry("messages/" + id + "?format=metadata&metadataHeaders=To&metadataHeaders=From&metadataHeaders=Subject");
  const names: string[] = [];
  try {
    const full = await gmRetry("messages/" + id + "?format=full");
    const walk = (p: any) => {
      if (!p) return;
      if (p.filename) names.push(String(p.filename));
      for (const c of p.parts || []) walk(c);
    };
    walk(full.payload);
  } catch { /* metadata is enough if the second read fails */ }
  return { from: hdr(m, "From"), to: hdr(m, "To"), subject: hdr(m, "Subject"), attachment_names: names };
}

async function alreadySent(cid: string) {
  const { data } = await SB.from("messages").select("external_id").eq("conversation_id", cid).like("external_id", "note:marketing-forward%");
  return (data || []).some((r: any) => r.external_id !== PENDING);
}
async function acquireLock(cid: string, again: boolean): Promise<{ id: string } | { busy: true } | { sent: true } | { error: string }> {
  const { data: pending } = await SB.from("messages").select("id,sent_at,body").eq("conversation_id", cid).eq("external_id", PENDING).maybeSingle();
  if (pending?.id) {
    if (String(pending.body || "").startsWith("Sent to marketing")) {
      if (!again) return { sent: true };
      await SB.from("messages").update({ external_id: "note:marketing-forward:" + new Date().toISOString() }).eq("id", pending.id).eq("external_id", PENDING);
    } else {
      const age = Date.now() - Date.parse(pending.sent_at || 0);
      if (Number.isFinite(age) && age < 5 * 60 * 1000) return { busy: true };
      await SB.from("messages").delete().eq("id", pending.id);
    }
  }
  const { data, error } = await SB.from("messages").insert({
    conversation_id: cid,
    direction: "note",
    author: "Eggsy CX",
    body: "Sending to marketing…",
    sent_at: new Date().toISOString(),
    external_id: PENDING,
  }).select("id").single();
  if (error) {
    if (error.code === "23505") return { busy: true };
    return { error: "Could not start the send" };
  }
  return { id: data.id };
}
async function releaseLock(id: string) {
  await SB.from("messages").delete().eq("id", id).eq("external_id", PENDING);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  let p: any = {};
  try { p = await req.json(); } catch { /* */ }
  const test = p.mode === "format-test";
  let by = "";
  if (test) {
    const secret = req.headers.get("x-eggsy-hook") || "";
    const { data: ok } = secret ? await SB.rpc("cx_email_hook_ok", { p_secret: secret }) : { data: false };
    if (ok !== true) return json({ error: "Forbidden" }, 403);
    by = "format-test@luckyegg.co";
  } else {
    const auth = req.headers.get("Authorization") || "";
    const user = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY") || "sb_publishable_gX9OKDCT6Opnt8OcsFRmiQ_xaM0O8ti", { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data: staff } = await user.rpc("is_lucky_egg_staff");
    if (staff !== true) return json({ error: "Forbidden" }, 403);
    const { data: u } = await user.auth.getUser();
    by = String(u?.user?.email || "").trim().toLowerCase();
    if (!by.endsWith("@luckyegg.co")) return json({ error: "Forbidden" }, 403);
  }

  const cid = String(p.conversation_id || "");
  if (!/^[0-9a-f-]{36}$/i.test(cid)) return json({ error: "Bad conversation id" }, 400);
  const again = p.again === true;
  const to = test ? TEST_TO : await marketingTo();
  if (to !== lucky(to)) return json({ error: "Marketing address is not an @luckyegg.co address" }, 500);
  if (test && to !== TEST_TO) return json({ error: "Format test can only go to hey@luckyegg.co" }, 500);

  const { data: conv } = await SB.from("conversations").select("id,origin,customer_name,customer_handle,subject,order_number,overview,status").eq("id", cid).maybeSingle();
  if (!conv) return json({ error: "Ticket not found" }, 404);
  const { data: rows, error: rowErr } = await SB.from("messages").select("direction,author,body,sent_at,external_id").eq("conversation_id", cid).order("sent_at", { ascending: true }).limit(300);
  if (rowErr) return json({ error: "Could not read the ticket" }, 500);

  let lockId = "";
  if (!test) {
    if (!again && await alreadySent(cid)) return json({ ok: false, error: "already_sent", message: "Already sent to marketing. Use Send again if you mean to send it another time." }, 409);
    const lock = await acquireLock(cid, again);
    if ("sent" in lock) return json({ ok: false, sent: true, error: "already_sent", message: "Already sent to marketing. Use Send again if you mean to send it another time." }, 409);
    if ("busy" in lock) return json({ ok: false, error: "busy", message: "A send to marketing is already in progress." }, 409);
    if ("error" in lock) return json({ ok: false, error: "lock", message: lock.error }, 500);
    lockId = lock.id;
    if (!again && await alreadySent(cid)) {
      await releaseLock(lockId);
      return json({ ok: false, error: "already_sent", message: "Already sent to marketing. Use Send again if you mean to send it another time." }, 409);
    }
  }

  try {
    const emailish = EMAIL_ORIGINS.has(String(conv.origin || ""));
    const made = (emailish ? await composeEmail(conv, rows || [], by) : null) || composeTranscript(conv, rows || [], by, emailish ? "The original email was not in hey@, so attachments could not be included. This is the conversation Eggsy has stored." : undefined);
    let subject = made.subject;
    if (test) subject = "[Eggsy format test] " + subject;
    const checks = checksFor(made.kind, made.plain, made.subject, by, cid);
    if (!checks.header || !checks.ticket || !checks.fwd_subject) {
      if (lockId) await releaseLock(lockId);
      return json({ ok: false, error: "format", message: "The forward could not be formatted.", checks }, 500);
    }
    const sent = await gmRetry("messages/send", { raw: buildRaw(to, subject, made.plain, made.atts) });
    let gmail_confirmed: any = null;
    try { gmail_confirmed = await confirmSent(sent.id); } catch { /* send already succeeded */ }
    const payload = {
      ok: true,
      to,
      subject,
      gmail: sent.id,
      kind: made.kind,
      attachments: made.atts.map((a) => ({ filename: a.filename, bytes: a.bytes.length })),
      skipped: made.skipped,
      original_chars: made.original_chars,
      checks,
      gmail_confirmed,
      test,
    };
    console.log(JSON.stringify({ ok: true, test, to, gmail: sent.id, kind: made.kind, attachments: made.atts.length }));
    if (test) return json(payload);

    const note = "Sent to marketing (" + to + ") by " + by + " at " + ukStamp();
    const finalExt = again ? "note:marketing-forward:" + new Date().toISOString() : "note:marketing-forward";
    const { error: noteErr } = await SB.from("messages").update({
      body: note,
      external_id: finalExt,
      sent_at: new Date().toISOString(),
    }).eq("id", lockId).eq("external_id", PENDING);
    if (noteErr) {
      await SB.from("messages").update({ body: note }).eq("id", lockId);
      const holding = await placeHoldingReply(cid);
      return json({ ok: false, sent: true, to, gmail: sent.id, error: "note", holding, message: "The email was sent, but the note could not be saved. Do not send it again unless you mean to." }, 500);
    }
    const { error: stErr } = await SB.from("conversations").update({
      status: "resolved",
      status_changed_at: new Date().toISOString(),
    }).eq("id", cid);
    const holding = await placeHoldingReply(cid);
    if (stErr) {
      return json({ ok: false, sent: true, to, gmail: sent.id, error: "status", holding, message: "The email was sent and the note was saved, but the ticket could not be marked Resolved." }, 500);
    }
    return json({ ...payload, holding });
  } catch (e) {
    if (lockId) await releaseLock(lockId);
    const st = (e as any).status || 0;
    console.error("forward-to-marketing: " + String((e as Error).message).slice(0, 180));
    const message = isRateLimited(e)
      ? "Gmail is rate limiting hey@ (" + (st || "quota") + "). Wait a moment and try again. Nothing was sent."
      : "Could not send from hey@ (" + (st || "network") + "). Nothing was sent.";
    return json({ ok: false, error: "gmail", message }, 502);
  }
});
