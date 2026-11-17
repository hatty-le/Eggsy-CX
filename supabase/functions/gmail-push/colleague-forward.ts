/** Auto-forward named-colleague and Marty creative-collaboration mail from hey@. */
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { b64, mimeAlternative } from "./format.ts";
import {
  EMAIL_CS_ORIGINS,
  isCreativeCollaboration,
  isProtectedCsCustomerThread,
  namedPersonSalutation,
} from "./mail-rules.ts";

export const FUNCTION_VERSION = 19;
const FROM = "hey@luckyegg.co";
const TEST_TO = "hey@luckyegg.co";
const TICKET_ORIGIN = "https://eggsy-cx.vercel.app";
const MAX_ATTACH = 20 * 1024 * 1024;
const GMAIL_PREFIX = "gmail:";
const NOTE_PREFIX = "note:auto-forward:";
const NOTE_PENDING = "note:auto-forward:pending";
const MARTY_INTRO = "Hey Marty, Is this one for you?";
const COLLEAGUE_INTRO = "Forwarded automatically from hey@ by Eggsy CX – addressed to you.";

export type GmFn = (path: string, init?: RequestInit) => Promise<any>;

export type Colleague = {
  id: string;
  first_name: string;
  aliases: string[] | null;
  email: string;
  display_name: string | null;
  last_name: string | null;
  active: boolean;
};

type Att = { filename: string; mime: string; bytes: Uint8Array };
type Conv = {
  id: string;
  origin?: string;
  status?: string;
  customer_name?: string | null;
  customer_handle?: string | null;
  subject?: string | null;
  order_number?: string | null;
  last_message_at?: string | null;
};

const enc = new TextEncoder();
const clean = (s: string) => String(s || "").replace(/[\r\n]+/g, " ").trim();
const sleep = (ms: number) => new Promise((res) => setTimeout(res, ms));

function encWord(s: string) {
  if (/^[\x20-\x7e]*$/.test(s)) return s;
  const out: string[] = [];
  let cur = "";
  for (const ch of s) {
    if (enc.encode(cur + ch).length > 42) {
      out.push(cur);
      cur = "";
    }
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
  try {
    return new TextDecoder().decode(fromB64Url(d));
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
function hdr(m: any, n: string) {
  return (m?.payload?.headers || []).find((h: any) => h.name.toLowerCase() === n.toLowerCase())?.value || "";
}
function partHdr(p: any, n: string) {
  return (p?.headers || []).find((h: any) => h.name.toLowerCase() === n.toLowerCase())?.value || "";
}
function textOf(p: any): string {
  if (!p) return "";
  if (!p.filename && p.mimeType === "text/plain" && p.body?.data) return decodeText(p.body.data);
  // Prefer a single text/plain part so multipart/alternative is not pasted twice.
  const parts = p.parts || [];
  for (const c of parts) {
    if (!c.filename && c.mimeType === "text/plain" && c.body?.data) {
      const t = decodeText(c.body.data).trim();
      if (t) return t;
    }
  }
  for (const c of parts) {
    const t = textOf(c).trim();
    if (t) return t;
  }
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
function isRateLimited(e: any): boolean {
  const st = e?.status || 0;
  if (st === 429) return true;
  if (st !== 403) return false;
  return /rateLimitExceeded|userRateLimitExceeded|quotaExceeded|RESOURCE_EXHAUSTED/i.test(e?.reason || e?.message || "");
}
const BACKOFF_MS = [1000, 2000, 4000, 8000];
async function gmRetry(gm: GmFn, path: string, init?: RequestInit) {
  for (let i = 0; ; i++) {
    try {
      return await gm(path, init);
    } catch (e) {
      if (!isRateLimited(e) || i >= BACKOFF_MS.length) throw e;
      const wait = BACKOFF_MS[i] + Math.floor(Math.random() * BACKOFF_MS[i]);
      console.warn("Gmail rate limit retry " + (i + 1));
      await sleep(wait);
    }
  }
}

function collectParts(p: any, out: any[]) {
  if (!p) return;
  const name = String(p.filename || "").trim();
  const disp = partHdr(p, "Content-Disposition");
  const isFile = !!name || /^attachment/i.test(disp);
  if (isFile && !String(p.mimeType || "").startsWith("multipart/") && (p.body?.attachmentId || p.body?.data)) out.push(p);
  for (const c of p.parts || []) collectParts(c, out);
}

async function loadAttachments(gm: GmFn, messageId: string, payload: any): Promise<{ atts: Att[]; skipped: string[] }> {
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
        const j = await gmRetry(gm, "messages/" + messageId + "/attachments/" + encodeURIComponent(p.body.attachmentId));
        bytes = j?.data ? fromB64Url(j.data) : null;
      }
      if (!bytes?.length) {
        skipped.push(filename + " (empty)");
        continue;
      }
      if (total + bytes.length > MAX_ATTACH) {
        skipped.push(filename + " (too large to include)");
        continue;
      }
      total += bytes.length;
      atts.push({ filename, mime: clean(p.mimeType || "application/octet-stream") || "application/octet-stream", bytes });
    } catch (e) {
      if (isRateLimited(e)) throw e;
      skipped.push(filename + " (could not be fetched)");
    }
  }
  return { atts, skipped };
}

function buildRaw(to: string, subject: string, plain: string, atts: Att[], replyTo?: string) {
  const alt = mimeAlternative(plain);
  const head = [
    "From: Lucky Egg <" + FROM + ">",
    "To: " + clean(to),
    ...(replyTo ? ["Reply-To: " + clean(replyTo)] : []),
    "Subject: " + encWord(clean(subject)),
    "MIME-Version: 1.0",
  ];
  let lines: string[];
  if (!atts.length) lines = [...head, ...alt];
  else {
    const boundary = "eggsy_mix_" + crypto.randomUUID().replace(/-/g, "");
    lines = [...head, 'Content-Type: multipart/mixed; boundary="' + boundary + '"', "", "--" + boundary, ...alt];
    for (const a of atts) {
      lines.push(
        "--" + boundary,
        "Content-Type: " + a.mime + '; name="' + a.filename + '"',
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

function ticketLine(cid: string) {
  return "Ticket: " + TICKET_ORIGIN + "/inbox/?c=" + cid;
}

export async function loadColleagues(sb: SupabaseClient): Promise<Colleague[]> {
  const { data, error } = await sb
    .from("cx_colleagues")
    .select("id, first_name, aliases, email, display_name, last_name, active")
    .eq("active", true);
  if (error) throw error;
  return (data || []) as Colleague[];
}

/** First names Hatty confirmed are not current colleagues. Do not auto-forward or leave a "who should get this" note. */
const RETIRED_FIRST_NAMES = new Set(["rohan"]);

const TOPIC_EMAILS: Record<string, { sales?: string; product_design?: string; marketing?: string }> = {
  ben: { sales: "ben.p@luckyegg.co", product_design: "ben@luckyegg.co" },
  claudia: { sales: "claudia.bb@luckyegg.co", marketing: "claudia@luckyegg.co" },
};

function lastNameHints(c: Colleague): string[] {
  const out = new Set<string>();
  const add = (s: string) => {
    const t = s.toLowerCase().trim();
    if (t) out.add(t);
  };
  add(c.last_name || "");
  add(c.display_name || "");
  const parts = (c.display_name || "").split(/\s+/);
  for (const p of parts.slice(1)) add(p.replace(/[."]+$/g, ""));
  // Claudia BB / Claudia.bb
  if ((c.email || "").includes(".bb@") || /bettson/i.test(c.display_name || "") || /bettson/i.test(c.last_name || "")) {
    add("bb");
    add("bettson-burdett");
    add("bettson");
  }
  return [...out];
}

function topicSignals(subject: string, body: string): { sales: boolean; productDesign: boolean; marketing: boolean } {
  const hay = `${subject}\n${body}`.toLowerCase();
  const sales = /\b(?:sales?|wholesale|wholesaler|trade account|trade price|retail(?:er)?s?\b|distribu(?:tor|tion|te)|stockists?|\bb2b\b|faire\b|price list|line sheet|stock (?:our|your) games|buy(?:ing)? from you|purchase (?:some |the )?games|export|merchandis|sales (?:call|meeting|account)|timeslot with you)\b/.test(hay);
  const productDesign = /\b(?:product design|product (?:and|&) design|game design|card design|graphic design|illustrat(?:or|ion|e|ing)|artwork|packaging|prototype|components?|rulebook|3d model|product dev(?:elopment)?|design team|game mechanic)\b/.test(hay);
  const marketing = /\b(?:marketing|campaign|press coverage|\bpr\b|publicity|influencers?|social media|paid ads?|advertising|content creator|newsletter|launch campaign|brand (?:campaign|partnership|collab)|head of marketing)\b/.test(hay);
  return { sales, productDesign, marketing };
}

function disambiguateByTopic(
  first: string,
  candidates: Colleague[],
  subject: string,
  body: string,
): Colleague | "unclear" {
  const map = TOPIC_EMAILS[first];
  if (!map) return "unclear";
  const sig = topicSignals(subject, body);
  const wants: string[] = [];
  if (sig.sales && map.sales) wants.push(map.sales);
  if (sig.productDesign && map.product_design) wants.push(map.product_design);
  if (sig.marketing && map.marketing) wants.push(map.marketing);
  const unique = [...new Set(wants)];
  if (unique.length !== 1) return "unclear";
  return candidates.find((c) => c.email === unique[0]) || "unclear";
}

export function matchColleague(
  salutation: { name: string; rest: string[] },
  colleagues: Colleague[],
  subject = "",
  body = "",
): { kind: "unique"; colleague: Colleague } | { kind: "ambiguous"; matches: Colleague[] } | { kind: "unknown" } | { kind: "retired" } {
  const first = salutation.name.toLowerCase();
  if (RETIRED_FIRST_NAMES.has(first) && !salutation.rest.length) return { kind: "retired" };
  let candidates = colleagues.filter((c) => {
    const names = new Set([c.first_name, ...((c.aliases || []).map((a) => a.toLowerCase()))]);
    return names.has(first);
  });
  if (salutation.rest.length) {
    const last = salutation.rest.join(" ").toLowerCase();
    const narrowed = candidates.filter((c) => lastNameHints(c).some((h) => h === last || h.endsWith(last) || last.endsWith(h)));
    if (narrowed.length) candidates = narrowed;
  }
  if (candidates.length === 1) return { kind: "unique", colleague: candidates[0] };
  if (candidates.length > 1) {
    const byTopic = disambiguateByTopic(first, candidates, subject, body);
    if (byTopic !== "unclear") return { kind: "unique", colleague: byTopic };
    return { kind: "ambiguous", matches: candidates };
  }
  return { kind: "unknown" };
}

async function alreadyForwarded(sb: SupabaseClient, cid: string, sourceExt: string): Promise<boolean> {
  const noteId = NOTE_PREFIX + sourceExt;
  const { data: notes } = await sb.from("messages").select("external_id").eq("conversation_id", cid).eq("external_id", noteId);
  if (notes?.length) return true;
  const { data: acts } = await sb
    .from("cx_actions")
    .select("id")
    .eq("conversation_id", cid)
    .eq("type", "forward")
    .contains("details", { source_external_id: sourceExt });
  if (acts?.length) return true;
  return false;
}

async function addNote(sb: SupabaseClient, cid: string, body: string, externalId: string) {
  const { error } = await sb.from("messages").insert({
    conversation_id: cid,
    direction: "note",
    author: "Eggsy CX",
    body,
    sent_at: new Date().toISOString(),
    external_id: externalId,
  });
  if (error && !String(error.message || "").toLowerCase().includes("duplicate")) {
    console.error("auto-forward note failed", cid, error.message);
  }
}

async function supersedeDrafts(sb: SupabaseClient, cid: string) {
  const now = new Date().toISOString();
  await sb.from("suggested_drafts").update({ superseded: true, superseded_at: now }).eq("conversation_id", cid).eq("superseded", false);
  await sb.from("reply_queue").update({
    status: "cancelled",
    cancelled_at: now,
    cancelled_by: "eggsy-auto-forward",
    updated_at: now,
  }).eq("conversation_id", cid).in("status", ["queued", "ready", "sending"]);
}

function composePlain(opts: {
  kind: "colleague" | "creative";
  cid: string;
  from: string;
  date: string;
  subject: string;
  to: string;
  body: string;
  skipped: string[];
}) {
  const intro = opts.kind === "creative" ? MARTY_INTRO : COLLEAGUE_INTRO;
  const lines = [
    intro,
    "",
    ticketLine(opts.cid),
    "",
    "---------- Forwarded message ---------",
    "From: " + opts.from,
    "Date: " + (opts.date || "unknown"),
    "Subject: " + opts.subject,
  ];
  if (opts.to) lines.push("To: " + opts.to);
  lines.push("", opts.body || "(no message body)");
  if (opts.skipped.length) {
    lines.push("", "Some attachments could not be included:");
    for (const s of opts.skipped) lines.push("- " + s);
  }
  return lines.join("\n");
}

async function composeFromGmail(
  gm: GmFn,
  conv: Conv,
  sourceExt: string,
  kind: "colleague" | "creative",
  storedBody: string,
  storedSubject: string,
  storedFrom: string,
  storedDate: string,
) {
  let orig: any = null;
  const mid = sourceExt.startsWith(GMAIL_PREFIX) ? sourceExt.slice(GMAIL_PREFIX.length) : "";
  if (mid) {
    try {
      orig = await gmRetry(gm, "messages/" + mid + "?format=full");
    } catch (e) {
      // 404, quota or any fetch failure: still forward from the ticket body.
      console.warn("composeFromGmail using stored body", mid, e instanceof Error ? e.message : e);
      orig = null;
    }
  }
  const from = clean(orig ? hdr(orig, "From") : "") || storedFrom;
  const date = clean(orig ? hdr(orig, "Date") : "") || storedDate || (orig?.internalDate ? new Date(Number(orig.internalDate)).toUTCString() : "");
  const subject = clean(orig ? hdr(orig, "Subject") : "") || clean(storedSubject) || "(no subject)";
  const to = clean(orig ? hdr(orig, "To") : "");
  let body = orig ? textOf(orig.payload).replace(/\u0000/g, "").trim() : "";
  if (!body) body = (storedBody || "").trim();
  if (body.length > 200000) body = body.slice(0, 200000) + "\n\n[truncated]";
  let atts: Att[] = [];
  let skipped: string[] = [];
  if (orig?.id) {
    const got = await loadAttachments(gm, orig.id, orig.payload);
    atts = got.atts;
    skipped = got.skipped;
  }
  const replyTo = clean(orig ? (hdr(orig, "Reply-To") || hdr(orig, "From")) : storedFrom);
  const plain = composePlain({ kind, cid: conv.id, from, date, subject, to, body, skipped });
  return { subject: fwdSubject(subject), plain, atts, skipped, replyTo, original_chars: body.length };
}

function formatOk(kind: "colleague" | "creative", plain: string, subject: string, cid: string) {
  const intro = kind === "creative" ? MARTY_INTRO : COLLEAGUE_INTRO;
  return {
    intro: plain.startsWith(intro),
    ticket: plain.includes(TICKET_ORIGIN + "/inbox/?c=" + cid),
    from: /^From: /m.test(plain),
    date: /^Date: /m.test(plain),
    subject_line: /^Subject: /m.test(plain),
    fwd_subject: /^(\[Eggsy format test\]\s*)?fwd:/i.test(subject),
  };
}

async function sendMime(gm: GmFn, to: string, subject: string, plain: string, atts: Att[], replyTo?: string) {
  const raw = buildRaw(to, subject, plain, atts, replyTo);
  return await gmRetry(gm, "messages/send", { method: "POST", body: JSON.stringify({ raw }) });
}

async function recordForward(
  sb: SupabaseClient,
  conv: Conv,
  opts: {
    kind: "colleague" | "creative";
    toEmail: string;
    toName: string;
    sourceExt: string;
    gmailId: string;
    subject: string;
    test: boolean;
  },
) {
  if (opts.test) return;
  const now = new Date().toISOString();
  const note = opts.kind === "creative"
    ? "Forwarded automatically to Marty (" + opts.toEmail + ") as a creative collaboration. No customer reply was sent."
    : "Forwarded automatically to " + opts.toName + " (" + opts.toEmail + "). Addressed to them. No customer reply was sent.";
  await addNote(sb, conv.id, note, NOTE_PREFIX + opts.sourceExt);
  const { error: actErr } = await sb.from("cx_actions").insert({
    conversation_id: conv.id,
    type: "forward",
    status: "done",
    details: {
      kind: opts.kind,
      to: opts.toEmail,
      to_name: opts.toName,
      source_external_id: opts.sourceExt,
      gmail_id: opts.gmailId,
      subject: opts.subject,
    },
    created_by: "eggsy-auto-forward",
    completed_at: now,
    updated_at: now,
  });
  if (actErr && !String(actErr.message || "").toLowerCase().includes("duplicate")) {
    console.error("auto-forward action failed", conv.id, actErr.message);
  }
  const { data: lastMsg } = await sb
    .from("messages")
    .select("id")
    .eq("conversation_id", conv.id)
    .eq("external_id", NOTE_PREFIX + opts.sourceExt)
    .maybeSingle();
  const sentExt = "auto-forward:" + opts.gmailId;
  const { error: logErr } = await sb.from("sent_log").insert({
    sent_at: now,
    conversation_id: conv.id,
    message_id: lastMsg?.id || null,
    origin: conv.origin || "email_hey",
    shop: null,
    customer_name: conv.customer_name || null,
    customer_handle: conv.customer_handle || null,
    order_number: conv.order_number || null,
    channel: "email",
    body: note,
    route: opts.kind === "creative" ? "marty-creative-forward" : "colleague-forward",
    approved_by: "hatty-rule-2026-11-17",
    sent_by: "eggsy-auto-forward",
    external_id: sentExt,
  });
  if (logErr && !String(logErr.message || "").toLowerCase().includes("duplicate")) {
    console.error("auto-forward sent_log failed", conv.id, logErr.message);
  }
  await sb.from("conversations").update({ status: "resolved", status_changed_at: now, updated_at: now }).eq("id", conv.id);
  await supersedeDrafts(sb, conv.id);
}

export type ForwardPlan =
  | { action: "forward"; kind: "colleague" | "creative"; to: Colleague; reason: string }
  | { action: "note"; body: string; externalId: string }
  | { action: "skip"; reason: string };

export function planForward(opts: {
  origin: string;
  body: string;
  subject: string;
  orderNumber: string | null;
  hasPriorReply: boolean;
  colleagues: Colleague[];
  marty: Colleague | null;
}): ForwardPlan {
  if (!EMAIL_CS_ORIGINS.has(opts.origin)) return { action: "skip", reason: "not_email_origin" };
  const addressed = namedPersonSalutation(opts.body);
  if (addressed) {
    if (isProtectedCsCustomerThread(addressed.name, opts.orderNumber, opts.hasPriorReply)) {
      return { action: "skip", reason: "cs_protected" };
    }
    const match = matchColleague(addressed, opts.colleagues, opts.subject, opts.body);
    if (match.kind === "retired") {
      return { action: "skip", reason: "retired_name" };
    }
    if (match.kind === "unique") {
      return { action: "forward", kind: "colleague", to: match.colleague, reason: "addressed_to_" + match.colleague.first_name };
    }
    if (match.kind === "ambiguous") {
      const list = match.matches.map((c) => (c.display_name || c.first_name) + " <" + c.email + ">").join("; ");
      const topicHint = addressed.name.toLowerCase() === "ben"
        ? " Sales goes to Ben Pullen, product or design to Ben Green."
        : addressed.name.toLowerCase() === "claudia"
        ? " Sales goes to Claudia Bettson-Burdett, marketing to Claudia Swindale."
        : "";
      return {
        action: "note",
        body: "Addressed to " + addressed.name + " – topic was not clear enough to choose who it should go to (" + list + ")." + topicHint,
        externalId: "note:addressed-ambiguous:" + addressed.name.toLowerCase(),
      };
    }
    return {
      action: "note",
      body: "Addressed to " + addressed.name + " – no colleague email on file",
      externalId: "note:addressed-unknown:" + addressed.name.toLowerCase(),
    };
  }
  if (isCreativeCollaboration(opts.subject, opts.body) && opts.marty) {
    return { action: "forward", kind: "creative", to: opts.marty, reason: "creative_collaboration" };
  }
  return { action: "skip", reason: "no_rule" };
}

export async function maybeAutoForward(
  sb: SupabaseClient,
  gm: GmFn,
  opts: {
    conv: Conv;
    origin: string;
    body: string;
    subject: string;
    orderNumber: string | null;
    sourceExternalId: string;
    historical?: boolean;
    customerName?: string;
    sentAt?: string;
  },
): Promise<{ action: string; detail?: string }> {
  if (opts.historical) return { action: "skipped", detail: "historical" };
  if (!EMAIL_CS_ORIGINS.has(opts.origin)) return { action: "skipped", detail: "not_email_origin" };
  if (!opts.sourceExternalId) return { action: "skipped", detail: "no_source" };
  if (await alreadyForwarded(sb, opts.conv.id, opts.sourceExternalId)) return { action: "skipped", detail: "already_forwarded" };

  const colleagues = await loadColleagues(sb);
  const marty = colleagues.find((c) => c.email === "marty@luckyegg.co") || null;
  let hasPriorReply = false;
  const { data: outs } = await sb.from("messages").select("id").eq("conversation_id", opts.conv.id).eq("direction", "outbound").limit(1);
  hasPriorReply = Boolean(outs?.length);

  const plan = planForward({
    origin: opts.origin,
    body: opts.body,
    subject: opts.subject,
    orderNumber: opts.orderNumber,
    hasPriorReply,
    colleagues,
    marty,
  });
  if (plan.action === "skip") return { action: "skipped", detail: plan.reason };
  if (plan.action === "note") {
    await addNote(sb, opts.conv.id, plan.body, plan.externalId);
    return { action: "noted", detail: plan.body };
  }
  try {
    const made = await composeFromGmail(
      gm,
      opts.conv,
      opts.sourceExternalId,
      plan.kind,
      opts.body,
      opts.subject,
      [opts.customerName, opts.conv.customer_handle].filter(Boolean).join(" "),
      opts.sentAt || "",
    );
    const checks = formatOk(plan.kind, made.plain, made.subject, opts.conv.id);
    if (!checks.intro || !checks.fwd_subject || !checks.from) {
      await addNote(sb, opts.conv.id, "Addressed to " + (plan.to.display_name || plan.to.first_name) + " – forward could not be formatted. Needs retry.", "note:auto-forward-failed:" + opts.sourceExternalId);
      return { action: "format_failed" };
    }
    const toHeader = (plan.to.display_name ? plan.to.display_name + " <" + plan.to.email + ">" : plan.to.email);
    const sent = await sendMime(gm, toHeader, made.subject, made.plain, made.atts, made.replyTo);
    await recordForward(sb, opts.conv, {
      kind: plan.kind,
      toEmail: plan.to.email,
      toName: plan.to.display_name || plan.to.first_name,
      sourceExt: opts.sourceExternalId,
      gmailId: String(sent.id || ""),
      subject: made.subject,
      test: false,
    });
    return { action: "forwarded", detail: plan.kind + ":" + plan.to.email };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("auto-forward send failed", opts.conv.id, msg);
    await addNote(
      sb,
      opts.conv.id,
      "Addressed to " + (plan.to.display_name || plan.to.first_name) + " – forward failed and needs retry. Nothing was marked sent.",
      "note:auto-forward-failed:" + opts.sourceExternalId,
    );
    return { action: "send_failed", detail: msg.slice(0, 180) };
  }
}

export async function handleForwardModes(
  sb: SupabaseClient,
  gm: GmFn,
  body: any,
): Promise<{ handled: boolean; response?: Record<string, unknown> }> {
  const mode = String(body?.mode || "");
  if (mode !== "colleague_forward_test" && mode !== "colleague_forward") return { handled: false };
  const test = mode === "colleague_forward_test";
  const ids: string[] = [];
  if (body.conversation_id) ids.push(String(body.conversation_id));
  if (Array.isArray(body.conversation_ids)) ids.push(...body.conversation_ids.map((x: any) => String(x)));
  if (!ids.length) return { handled: true, response: { ok: false, error: "missing conversation_id" } };

  const colleagues = await loadColleagues(sb);
  const marty = colleagues.find((c) => c.email === "marty@luckyegg.co") || null;
  const results: any[] = [];

  for (const cid of ids) {
    const { data: conv } = await sb
      .from("conversations")
      .select("id, origin, status, customer_name, customer_handle, subject, order_number, last_message_at")
      .eq("id", cid)
      .maybeSingle();
    if (!conv) {
      results.push({ conversation_id: cid, ok: false, error: "not_found" });
      continue;
    }
    const { data: rows } = await sb
      .from("messages")
      .select("direction, body, sent_at, external_id, author")
      .eq("conversation_id", cid)
      .order("sent_at", { ascending: true });
    const inbound = (rows || []).filter((r: any) => r.direction === "inbound" && String(r.external_id || "").startsWith(GMAIL_PREFIX));
    const latest = inbound.length ? inbound[inbound.length - 1] : (rows || []).find((r: any) => r.direction === "inbound");
    if (!latest) {
      results.push({ conversation_id: cid, ok: false, error: "no_inbound" });
      continue;
    }
    const sourceExt = String(latest.external_id || "");
    if (!test && sourceExt && await alreadyForwarded(sb, cid, sourceExt)) {
      results.push({ conversation_id: cid, ok: true, action: "already_forwarded" });
      continue;
    }
    const hasPriorReply = (rows || []).some((r: any) => r.direction === "outbound");
    const plan = planForward({
      origin: String(conv.origin || ""),
      body: String(latest.body || ""),
      subject: String(conv.subject || ""),
      orderNumber: conv.order_number || null,
      hasPriorReply,
      colleagues,
      marty,
    });
    if (plan.action === "skip") {
      results.push({ conversation_id: cid, ok: true, action: "skipped", reason: plan.reason });
      continue;
    }
    if (plan.action === "note") {
      if (!test) await addNote(sb, cid, plan.body, plan.externalId);
      results.push({ conversation_id: cid, ok: true, action: "noted", note: plan.body });
      continue;
    }
    try {
    const made = await composeFromGmail(
      gm,
      conv,
      sourceExt,
      plan.kind,
      String(latest.body || ""),
      String(conv.subject || ""),
      [latest.author, conv.customer_name, conv.customer_handle].filter(Boolean).join(" "),
      String(latest.sent_at || ""),
    );
    let subject = made.subject;
    if (test) subject = "[Eggsy format test] " + subject;
    const checks = formatOk(plan.kind, made.plain, subject, cid);
    if (!checks.intro || !checks.fwd_subject || !checks.from) {
      results.push({ conversation_id: cid, ok: false, error: "format", checks });
      continue;
    }
    const to = test ? TEST_TO : (plan.to.display_name ? plan.to.display_name + " <" + plan.to.email + ">" : plan.to.email);
    if (test && to !== TEST_TO) {
      results.push({ conversation_id: cid, ok: false, error: "test_must_go_to_hey" });
      continue;
    }
    if (!test && /hey@luckyegg\.co/i.test(to)) {
      results.push({ conversation_id: cid, ok: false, error: "live_must_not_go_to_hey" });
      continue;
    }
    const sent = await sendMime(gm, to, subject, made.plain, made.atts, test ? undefined : made.replyTo);
    if (!test) {
      await recordForward(sb, conv, {
        kind: plan.kind,
        toEmail: plan.to.email,
        toName: plan.to.display_name || plan.to.first_name,
        sourceExt,
        gmailId: String(sent.id || ""),
        subject,
        test: false,
      });
    }
    results.push({
      conversation_id: cid,
      ok: true,
      action: test ? "format_test" : "forwarded",
      test,
      to,
      intended: plan.to.email,
      kind: plan.kind,
      subject,
      gmail: sent.id,
      checks,
      attachments: made.atts.map((a) => ({ filename: a.filename, bytes: a.bytes.length })),
    });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error("colleague_forward item failed", cid, msg);
      results.push({ conversation_id: cid, ok: false, error: "send_failed", message: msg.slice(0, 180) });
      continue;
    }
  }
  return { handled: true, response: { ok: results.every((r) => r.ok), mode, version: FUNCTION_VERSION, results } };
}

export { isCreativeCollaboration };
