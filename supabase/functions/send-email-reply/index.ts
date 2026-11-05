// send-email-reply: posts replies queued in Eggsy CX by email from hey@luckyegg.co (Gmail API),
// and checks hey@ for delivery-failure emails. Called only by the database (pg_net), authenticated by a
// shared secret kept in Supabase Vault. Never logs email bodies or secrets.
import { createClient } from "npm:@supabase/supabase-js@2";

const SB = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const FROM = "hey@luckyegg.co";
const TEST_PREFIX = "EGGSYTEST-";                       // self-test conversations: only ever send to our own mailbox
const TEST_TO = new Set(["hey@luckyegg.co", "eggsy-bounce-test@luckyegg.co"]);
const G = "https://gmail.googleapis.com/gmail/v1/users/me/";

let tok: string | null = null;
async function token() {
  if (tok) return tok;
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: Deno.env.get("GMAIL_CLIENT_ID")!, client_secret: Deno.env.get("GMAIL_CLIENT_SECRET")!, refresh_token: Deno.env.get("GMAIL_REFRESH_TOKEN")! }) });
  const j = await r.json();
  if (!r.ok || !j.access_token) throw new Error("Gmail sign-in failed (" + r.status + ")");
  return (tok = j.access_token);
}
async function gm(path: string, body?: unknown, method?: string) {
  const r = await fetch(G + path, { method: method || (body ? "POST" : "GET"), headers: { Authorization: "Bearer " + await token(), "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text(); let j: any = {}; try { j = t ? JSON.parse(t) : {}; } catch { /* */ }
  if (!r.ok) { const e: any = new Error("Gmail " + r.status + ": " + (j?.error?.message || "error").slice(0, 200)); e.status = r.status; throw e; }
  return j;
}
const hdr = (m: any, n: string) => (m?.payload?.headers || []).find((h: any) => h.name.toLowerCase() === n.toLowerCase())?.value || "";
const addrOf = (v: string) => (v.match(/<([^>]+)>/)?.[1] || v).trim().toLowerCase();

// ---- content rules ----
// Every channel: no [ ] placeholders. Marketplaces only (Amazon, TikTok, Walmart): no links to our own sites, no review requests, no marketing.
// Plain email to a customer (hey@ email, website form) may mention our website and hey@ address.
const MARKETPLACE = /^(amazon|tiktok|walmart)/;
function contentProblem(body: string, origin: string): string | null {
  const b = body.normalize("NFKC");
  if (/\[[^\]]*\]/.test(b)) return "it still contains [ ] placeholders that need filling in first";
  if (!MARKETPLACE.test(origin || "")) return null;
  if (/lucky\s*egg\s*\.\s*(co|com|uk|de|shop|store|net)\b|luckyegg\.|luckyegg\s*\.\s*co/i.test(b)) return "it mentions a Lucky Egg website or email address, which Amazon does not allow in buyer messages";
  if (/https?:\/\/|www\./i.test(b) && /(luckyegg|myshopify|shopify|instagram|tiktok|facebook|wixsite)/i.test(b)) return "it contains a link to our own shop or social pages";
  const review = [
    /\b(leave|write|post)\b[^.\n]{0,40}\b(review|rating|feedback|stars?)\b/i, /\b(give|share|drop|add)\b[^.\n]{0,25}\b(review|rating|stars)\b/i, /\b(5|five)[\s-]*stars?\b/i, /\breview\s+us\b/i,
    /\bpositive\s+(review|feedback|rating)\b/i, /\b(bewertung|rezension)\b[^.\n]{0,40}\b(abgeben|hinterlassen|schreiben)\b/i,
    /\b(abgeben|hinterlassen|schreiben)\b[^.\n]{0,40}\b(bewertung|rezension)\b/i, /\b(deja|dejar|dejarnos|escribir)\b[^.\n]{0,40}\b(reseña|valoración|opinión)\b/i,
    /\blaisser\b[^.\n]{0,40}\b(avis|commentaire|évaluation)\b/i, /\blasciare\b[^.\n]{0,40}\b(recensione|valutazione|feedback)\b/i, /\b(recensie|beoordeling)\b[^.\n]{0,30}\b(achterlaten|schrijven|geven)\b/i ];
  if (review.some((r) => r.test(b))) return "it asks the buyer for a review or rating, which Amazon does not allow";
  const mkt = [/\b(discount|promo|voucher|coupon)\s*code\b/i, /\b\d{1,2}\s?%\s*off\b/i, /\bnewsletter\b/i, /\bsubscribe\b/i, /\bfollow\s+us\b/i,
    /\b(check\s+out|try|see)\s+our\s+(other|new|latest)\b/i, /\b(rabatt|gutschein)code\b/i, /\bcódigo\s+de\s+descuento\b/i, /\bcode\s+promo\b/i, /\bcodice\s+sconto\b/i, /\bkortingscode\b/i];
  if (mkt.some((r) => r.test(b))) return "it reads as marketing (discount code, newsletter or other products), which Amazon does not allow";
  return null;
}

// ---- find the buyer's email thread in hey@ ----
async function findBuyerEmail(conv: any, ch: any, r: any) {
  const order = (conv.order_number || "").trim();
  const test = order.startsWith(TEST_PREFIX);
  if (!test && !ch.relay_domain) {
    // Plain email channels (e.g. Shopify form, when switched on): reply on the stored Gmail thread to the stored address.
    if (!r.to_address || !r.reply_to_message_id) return { why: "no customer email address or original email is stored for this conversation" };
    const m = await gm("messages/" + String(r.reply_to_message_id).replace(/^gmail:/, "") + "?format=metadata&metadataHeaders=Subject&metadataHeaders=Message-ID&metadataHeaders=References");
    const mid = hdr(m, "Message-ID");
    if (!mid) return { why: "the original email could not be found in hey@" };
    return { to: String(r.to_address).toLowerCase(), subject: hdr(m, "Subject"), messageIdHdr: mid, references: hdr(m, "References"), threadId: m.threadId };
  }
  if (!order) return { why: "no order number is stored on this conversation" };
  const q = (test ? "from:" + FROM : "from:" + ch.relay_domain) + ' "' + order.replace(/"/g, "") + '"';
  const list = await gm("messages?" + new URLSearchParams({ q, maxResults: "10", includeSpamTrash: "true" }));
  for (const it of list.messages || []) {
    const m = await gm("messages/" + it.id + "?format=metadata&metadataHeaders=From&metadataHeaders=Reply-To&metadataHeaders=Subject&metadataHeaders=Message-ID&metadataHeaders=References");
    const from = addrOf(hdr(m, "From")), rt = addrOf(hdr(m, "Reply-To"));
    let to = "";
    if (test) { to = rt && TEST_TO.has(rt) ? rt : from; if (!TEST_TO.has(to)) continue; if ((m.labelIds || []).includes("SENT") && !(m.labelIds || []).includes("INBOX")) continue; }
    else { const dom = "@" + String(ch.relay_domain).toLowerCase(); to = [rt, from].find((a) => a.endsWith(dom)) || ""; if (!to) continue; }
    const subj = hdr(m, "Subject"), mid = hdr(m, "Message-ID");
    if (!mid) continue;
    return { to, subject: subj, messageIdHdr: mid, references: hdr(m, "References"), threadId: m.threadId };
  }
  return { why: test ? "no test email found" : "there is no Amazon buyer email for order " + order + " in hey@ (Amazon is not emailing these buyer messages to hey@)" };
}

// ---- MIME ----
const b64 = (u8: Uint8Array) => { let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s); };
const enc = new TextEncoder();
function encWord(s: string) {
  if (/^[\x20-\x7e]*$/.test(s)) return s;
  const out: string[] = []; let cur = "";
  for (const ch of s) { if (enc.encode(cur + ch).length > 42) { out.push(cur); cur = ""; } cur += ch; }
  if (cur) out.push(cur);
  return out.map((p) => "=?UTF-8?B?" + b64(enc.encode(p)) + "?=").join("\r\n ");
}
const clean = (s: string) => s.replace(/[\r\n]+/g, " ").trim();
function buildRaw(to: string, subject: string, inReplyTo: string, refs: string, body: string) {
  const text = body.replace(/\r?\n/g, "\r\n");
  const bodyB64 = b64(enc.encode(text)).replace(/.{1,76}/g, "$&\r\n");
  const references = clean([refs, inReplyTo].filter(Boolean).join(" ")).split(/\s+/).slice(-20).join(" ");
  const mime = ["From: Lucky Egg <" + FROM + ">", "To: " + clean(to), "Subject: " + encWord(clean(subject)), "In-Reply-To: " + clean(inReplyTo),
    "References: " + references, "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "", bodyB64].join("\r\n");
  return b64(enc.encode(mime)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ---- send one queued reply ----
async function sendOne(id: string) {
  const { data: r } = await SB.from("reply_queue").select("*").eq("id", id).maybeSingle();
  if (!r || r.status !== "queued") return { id, result: "skipped (not queued)" };
  const { data: ch } = await SB.from("email_send_channels").select("*").eq("origin", r.origin).maybeSingle();
  if (!ch?.enabled) return { id, result: "skipped (channel not on)" };
  const { data: conv } = await SB.from("conversations").select("id,origin,order_number,customer_handle").eq("id", r.conversation_id).single();
  const test = (conv.order_number || "").startsWith(TEST_PREFIX);

  const problem = contentProblem(r.body || "", conv.origin);
  if (problem) {
    await SB.from("reply_queue").update({ status: "failed", email_attempted_at: new Date().toISOString(), send_error: "Not sent: " + problem + ". Edit and send again." }).eq("id", id).eq("status", "queued");
    return { id, result: "refused (content)" };
  }
  let found: any;
  try { found = await findBuyerEmail(conv, ch, r); } catch (e) { return { id, result: "lookup error, will retry", err: String((e as Error).message) }; }
  if (!found.to) {
    // Leave it queued so Eggsy posts it in Seller Central at its next check.
    await SB.from("reply_queue").update({ email_attempted_at: new Date().toISOString(), email_note: "Could not send by email: " + found.why + (conv.origin.startsWith("amazon") ? ". Eggsy will post it in Seller Central at its next check." : ". Eggsy will send it at its next check.") }).eq("id", id).eq("status", "queued");
    return { id, result: "left for Seller Central" };
  }
  if (test && !TEST_TO.has(found.to)) return { id, result: "blocked (test must go to our own mailbox)" };
  if (!test && conv.origin.startsWith("amazon") && !found.to.endsWith("@" + String(ch.relay_domain).toLowerCase())) return { id, result: "blocked (not a relay address)" };
  const subject = /^re:/i.test(found.subject.trim()) ? found.subject.trim() : "Re: " + found.subject.trim();

  // Claim (queued -> sending). Only one caller can win.
  const { data: claimed } = await SB.from("reply_queue").update({ status: "sending", sending_at: new Date().toISOString(), attempts: (r.attempts || 0) + 1, send_error: null,
    email_attempted_at: new Date().toISOString(), email_note: null, to_address: found.to, gmail_thread_id: found.threadId, email_subject: subject, email_in_reply_to: found.messageIdHdr })
    .eq("id", id).eq("status", "queued").select("id");
  if (!claimed?.length) return { id, result: "skipped (someone else claimed it)" };

  let sent: any;
  try { sent = await gm("messages/send", { raw: buildRaw(found.to, subject, found.messageIdHdr, found.references, r.body), threadId: found.threadId }); }
  catch (e) {
    const st = (e as any).status || 0;
    await SB.from("reply_queue").update({ status: "failed", send_error: "Gmail did not send it (" + (st || "network") + "). " + (st >= 500 || !st ? "Check hey@ Sent mail before sending again." : "Edit and send again.") }).eq("id", id).eq("status", "sending");
    return { id, result: "failed (gmail)" };
  }
  let ownMid = "";
  try { ownMid = hdr(await gm("messages/" + sent.id + "?format=metadata&metadataHeaders=Message-ID"), "Message-ID"); } catch { /* */ }
  const { error } = await SB.rpc("cx_email_mark_sent", { p_reply_id: id, p_gmail_id: sent.id, p_thread_id: sent.threadId, p_message_id_hdr: ownMid || null });
  if (error) return { id, result: "sent, but marking failed (row left in sending)", gmail: sent.id };
  return { id, result: "sent", gmail: sent.id, thread: sent.threadId };
}

// ---- delivery-failure check ----
function textOf(p: any): string {
  if (!p) return "";
  let s = "";
  if (p.body?.data && /^(text\/|message\/)/.test(p.mimeType || "")) { try { s += new TextDecoder().decode(Uint8Array.from(atob(p.body.data.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0))) + "\n"; } catch { /* */ } }
  for (const c of p.parts || []) s += textOf(c);
  return s;
}
async function bounceCheck() {
  const since = new Date(Date.now() - 8 * 864e5).toISOString();
  const { data: sentRows } = await SB.from("reply_queue").select("id,to_address,sent_at,gmail_sent_id,gmail_sent_thread_id,email_message_id,email_subject,conversation_id")
    .eq("send_route", "email").eq("status", "sent").is("bounced_at", null).gte("sent_at", since);
  if (!sentRows?.length) return { checked: 0, bounced: 0 };
  const q = 'newer_than:9d (from:mailer-daemon OR from:postmaster OR from:amazon.com OR from:amazon.co.uk) ("delivery failure" OR "delivery failed" OR undeliverable OR undelivered OR "could not be delivered" OR "wasn\'t delivered" OR "not delivered" OR "Delivery Status Notification" OR "message blocked" OR "has been blocked")';
  const list = await gm("messages?" + new URLSearchParams({ q, maxResults: "50", includeSpamTrash: "true" }));
  const ids = (list.messages || []).map((m: any) => m.id);
  if (!ids.length) return { checked: 0, bounced: 0 };
  const { data: seen } = await SB.from("email_bounce_seen").select("gmail_id").in("gmail_id", ids);
  const seenSet = new Set((seen || []).map((s: any) => s.gmail_id));
  let checked = 0, bounced = 0;
  for (const bid of ids) {
    if (seenSet.has(bid)) continue;
    const m = await gm("messages/" + bid + "?format=full"); checked++;
    const when = Number(m.internalDate || 0);
    const txt = (hdr(m, "Subject") + "\n" + textOf(m.payload)).toLowerCase();
    const hit = sentRows.find((r: any) => when >= Date.parse(r.sent_at) - 60e3 && (
      (r.gmail_sent_thread_id && m.threadId === r.gmail_sent_thread_id) ||
      (r.email_message_id && txt.includes(r.email_message_id.toLowerCase().replace(/[<>]/g, ""))) ||
      (r.to_address && txt.includes(r.to_address.toLowerCase()))));
    if (!hit) { await SB.from("email_bounce_seen").insert({ gmail_id: bid }); continue; }
    const subj = hdr(m, "Subject").replace(/[\r\n]+/g, " ").slice(0, 120);
    const { data: ok } = await SB.rpc("cx_email_mark_bounced", { p_reply_id: hit.id, p_bounce_gmail_id: bid, p_reason: "a delivery failure email arrived in hey@ (\u201c" + subj + "\u201d)" });
    if (ok) { bounced++; try { await gm("messages/" + bid + "/modify", { removeLabelIds: ["UNREAD"] }); } catch { /* */ } }
  }
  return { checked, bounced };
}

async function sweep() {
  const { data: chans } = await SB.from("email_send_channels").select("origin").eq("enabled", true);
  const origins = (chans || []).map((c: any) => c.origin);
  const out: any[] = [];
  if (origins.length) {
    const { data: rows } = await SB.from("reply_queue").select("id").eq("status", "queued").in("origin", origins).is("email_attempted_at", null)
      .lt("queued_at", new Date(Date.now() - 60e3).toISOString()).order("queued_at").limit(10);
    for (const r of rows || []) out.push(await sendOne(r.id));
  }
  let bounces: any = {};
  try { bounces = await bounceCheck(); } catch (e) { bounces = { error: String((e as Error).message) }; }
  return { swept: out, bounces };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = req.headers.get("x-eggsy-hook") || "";
  const { data: ok } = secret ? await SB.rpc("cx_email_hook_ok", { p_secret: secret }) : { data: false };
  if (ok !== true) return new Response("Forbidden", { status: 403 });
  let p: any = {}; try { p = await req.json(); } catch { /* */ }
  try {
    const res = p.mode === "sweep" ? await sweep() : p.reply_id ? await sendOne(String(p.reply_id)) : { error: "nothing to do" };
    console.log(JSON.stringify({ mode: p.mode || "send", res }));
    return new Response(JSON.stringify(res), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("send-email-reply error: " + String((e as Error).message).slice(0, 300));
    return new Response(JSON.stringify({ error: "internal" }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
