// forward-email: lets signed-in Lucky Egg staff forward a ticket to any active colleague in cx_colleagues.
// POST { conversation_id, to_email, mode: "handle" | "advice", note?, draft? }
// handle: forwards the customer's original email; the colleague's reply goes straight to the customer
//         (Reply-To), the ticket gets a "(Forwarded to X ...)" note and is marked Resolved. Email tickets only.
// advice: emails the colleague the whole ticket from Eggsy (any channel) with our question and draft, plus the
//         original email attached when there is one; their reply comes back to hey@ and the
//         cx_marty_advice_reply trigger files it on the ticket as "(X's advice)".
// Recipients must be active @luckyegg.co colleagues, so this can never forward to an outside address.
// Legacy: to: "claudia-bb" (handle) and to: "marty" (advice) still work.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SB = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const G = "https://gmail.googleapis.com/gmail/v1/users/me/";
const FROM = "hey@luckyegg.co";
const LEGACY: Record<string, { email: string; mode: string }> = {
  "claudia-bb": { email: "claudia.bb@luckyegg.co", mode: "handle" },
  "marty": { email: "marty@luckyegg.co", mode: "advice" },
};
const ORIGINS: Record<string, string> = { email_hey: "hey@ email", shopify_form: "Shopify form", wix_mmc_form: "MMC Wix form", tiktok_uk: "TikTok UK", tiktok_eu: "TikTok EU", tiktok_us: "TikTok US", walmart: "Walmart", facebook: "Facebook", instagram: "Instagram" };
const chName = (o: string) => ORIGINS[o] || (o.startsWith("amazon_") ? "Amazon " + o.slice(7).toUpperCase() : o);
const ukTime = (d: string) => new Date(d).toLocaleString("en-GB", { timeZone: "Europe/London", day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

let tok: string | null = null;
async function token() {
  if (tok) return tok;
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: Deno.env.get("GMAIL_CLIENT_ID")!, client_secret: Deno.env.get("GMAIL_CLIENT_SECRET")!, refresh_token: Deno.env.get("GMAIL_REFRESH_TOKEN")! }) });
  const j = await r.json();
  if (!r.ok || !j.access_token) throw new Error("Gmail sign-in failed");
  return (tok = j.access_token);
}
async function gm(path: string, body?: unknown) {
  const r = await fetch(G + path, { method: body ? "POST" : "GET", headers: { Authorization: "Bearer " + await token(), "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  if (!r.ok) { const e: any = new Error("Gmail " + r.status); e.status = r.status; throw e; }
  return r.json();
}
const hdr = (m: any, n: string) => (m?.payload?.headers || []).find((h: any) => h.name.toLowerCase() === n.toLowerCase())?.value || "";
const enc = new TextEncoder();
const b64 = (u8: Uint8Array) => { let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s); };
const fromB64Url = (d: string) => { const s = atob(d.replace(/-/g, "+").replace(/_/g, "/")); return Uint8Array.from(s, (c) => c.charCodeAt(0)); };
const clean = (s: string) => s.replace(/[\r\n]+/g, " ").trim();
function encWord(s: string) {
  if (/^[\x20-\x7e]*$/.test(s)) return s;
  const out: string[] = []; let cur = "";
  for (const ch of s) { if (enc.encode(cur + ch).length > 42) { out.push(cur); cur = ""; } cur += ch; }
  if (cur) out.push(cur);
  return out.map((p) => "=?UTF-8?B?" + b64(enc.encode(p)) + "?=").join("\r\n ");
}
function textOf(p: any): string {
  if (!p) return "";
  if (p.mimeType === "text/plain" && p.body?.data) { try { return new TextDecoder().decode(fromB64Url(p.body.data)); } catch { return ""; } }
  for (const c of p.parts || []) { const t = textOf(c); if (t) return t; }
  return "";
}
// Same id repair as gmail-attachment: older Grok imports carry ids hey@ does not know.
async function resolve(mid: string, row: any, email: string) {
  try { return await gm("messages/" + mid + "?format=full"); } catch (e) { if (![400, 404].includes((e as any).status)) throw e; }
  if (!email.includes("@") || !row.sent_at) return null;
  const t = Math.floor(Date.parse(row.sent_at) / 1000);
  const list = await gm("messages?" + new URLSearchParams({ q: 'from:"' + email + '" after:' + (t - 900) + " before:" + (t + 900), maxResults: "5", includeSpamTrash: "true" }));
  const it = (list.messages || [])[0];
  return it ? await gm("messages/" + it.id + "?format=full") : null;
}

const b64url = (s: string) => b64(enc.encode(s)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const lines76 = (u8: Uint8Array) => b64(u8).replace(/.{1,76}/g, "$&\r\n");
// Advice: the whole ticket as Eggsy has it, so it works for TikTok, Amazon, Walmart and social too.
async function adviceEmail(to: any, conv: any, orig: any, note: string, draft: string, by: string, originUrl: unknown) {
  const { data: msgs } = await SB.from("messages").select("direction,author,sent_at,body,body_en,language").eq("conversation_id", conv.id).in("direction", ["inbound", "outbound"]).order("sent_at", { ascending: true }).limit(60);
  const who = conv.customer_name || conv.customer_handle || "the customer";
  const ticket = (String(originUrl || "").match(/^https:\/\/[a-z0-9.-]+$/i) ? originUrl : "https://eggsy-cx.vercel.app") + "/inbox/?c=" + conv.id;
  const convo = (msgs || []).map((m: any) => {
    const head = (m.direction === "inbound" ? who + " (customer)" : "Lucky Egg" + (m.author ? " (" + m.author + ")" : "")) + ", " + ukTime(m.sent_at) + ":";
    const text = String(m.direction === "inbound" && m.body_en && m.language && m.language !== "en" ? m.body_en + "\n[translated to English]" : m.body || "").trim();
    return head + "\n" + text;
  }).join("\n\n");
  const body = [
    "Hi " + to.name.split(" ")[0] + ",", "",
    "Could I get your advice on this customer ticket?", "",
    "OUR QUESTION", note, "",
    ...(draft ? ["OUR DRAFT REPLY SO FAR", draft, ""] : []),
    "THE TICKET",
    "Customer: " + who + (conv.customer_handle && conv.customer_handle !== who ? " (" + conv.customer_handle + ")" : ""),
    "Channel: " + chName(conv.origin) + (conv.shop && conv.shop !== chName(conv.origin) ? " · " + conv.shop : ""),
    ...(conv.order_number ? ["Order: " + conv.order_number] : []),
    ...(conv.overview ? ["Summary: " + conv.overview] : []),
    "Open in Eggsy: " + ticket, "",
    "FULL CONVERSATION", convo || "(no messages stored)", "",
    "Just reply to this email. Your reply goes into the ticket in Eggsy (asked by " + by + "), not to the customer.",
    ...(orig ? ["The customer's original email is attached."] : []),
  ].join("\r\n");
  const boundary = "eggsy_adv_" + crypto.randomUUID().replace(/-/g, "");
  const subj = "Advice needed: " + who + " (" + chName(conv.origin) + (conv.order_number ? ", order " + conv.order_number : "") + ")";
  const parts = ["--" + boundary, "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "", lines76(enc.encode(body))];
  if (orig) {
    const raw = await gm("messages/" + orig.id + "?format=raw");
    parts.push("--" + boundary, 'Content-Type: message/rfc822; name="customer-email.eml"', 'Content-Disposition: attachment; filename="customer-email.eml"', "Content-Transfer-Encoding: base64", "", lines76(fromB64Url(raw.raw)));
  }
  // No Reply-To: Marty's reply comes back to hey@ on this thread, and the cx_marty_advice_reply trigger
  // files it on the ticket as "(Marty's advice)".
  const mime = ["From: Lucky Egg <" + FROM + ">", "To: " + to.name + " <" + to.email + ">",
    "Subject: " + encWord(clean(subj)), "MIME-Version: 1.0", 'Content-Type: multipart/mixed; boundary="' + boundary + '"', "", ...parts, "--" + boundary + "--", ""].join("\r\n");
  const sent = await gm("messages/send", { raw: b64url(mime) });
  // The marker carries the sent email's own Gmail id, so the hey@ sync skips it as a duplicate.
  const first = to.name.split(" ")[0];
  await SB.from("messages").insert({ conversation_id: conv.id, direction: "note", author: "Sent to " + first + " for advice",
    body: "(Sent to " + first + " for advice by " + by + ") " + note, sent_at: new Date().toISOString(),
    external_id: "gmail:" + sent.id, external_thread_id: sent.threadId });
  await SB.from("cx_followups").insert({ conversation_id: conv.id, kind: "advice", title: "Waiting on advice from " + first,
    details: note, assignees: first + " <" + to.email + ">", created_by: by, gmail_thread_id: sent.threadId });
  return { ok: true, gmail: sent.id, thread: sent.threadId, forwarded_message: orig?.id || null, to: to.email };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const auth = req.headers.get("Authorization") || "";
  const user = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY") || "sb_publishable_gX9OKDCT6Opnt8OcsFRmiQ_xaM0O8ti", { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: staff } = await user.rpc("is_lucky_egg_staff");
  if (staff !== true) return json({ error: "Forbidden" }, 403);
  const { data: u } = await user.auth.getUser();
  const by = String(u?.user?.email || "a teammate").toLowerCase();

  let p: any = {}; try { p = await req.json(); } catch { /* */ }
  const legacy = LEGACY[String(p.to || "")];
  const toEmail = String(p.to_email || legacy?.email || "").trim().toLowerCase();
  const mode = String(p.mode || legacy?.mode || "handle") === "advice" ? "advice" : "handle";
  if (!/^[^@\s]+@luckyegg\.co$/.test(toEmail)) return json({ error: "Pick a Lucky Egg colleague" }, 400);
  const { data: col } = await SB.from("cx_colleagues").select("email,display_name,first_name,last_name,active").eq("email", toEmail).eq("active", true).maybeSingle();
  if (!col) return json({ error: "That colleague is not in the list" }, 400);
  const nm = String(col.display_name || [col.first_name, col.last_name].filter(Boolean).join(" ") || toEmail);
  const to = { email: toEmail, name: nm.charAt(0).toUpperCase() + nm.slice(1), advice: mode === "advice" };
  const cid = String(p.conversation_id || "");
  if (!/^[0-9a-f-]{36}$/i.test(cid)) return json({ error: "Bad conversation id" }, 400);
  const note = String(p.note || "").slice(0, 4000).trim();
  const draft = String(p.draft || "").slice(0, 8000).trim();
  if (to.advice && !note) return json({ error: "Write your question for " + to.name.split(" ")[0] + " first." }, 400);

  const { data: conv } = await SB.from("conversations").select("id,origin,shop,customer_name,customer_handle,subject,order_number,overview").eq("id", cid).maybeSingle();
  if (!conv) return json({ error: "Ticket not found" }, 404);
  const { data: rows } = await SB.from("messages").select("id,external_id,sent_at").eq("conversation_id", cid).eq("direction", "inbound").like("external_id", "gmail:%").order("sent_at", { ascending: false }).limit(3);
  const handle = String(conv.customer_handle || "").trim().toLowerCase();
  try {
    let orig: any = null;
    try { for (const r of rows || []) { orig = await resolve(String(r.external_id).slice(6), r, handle); if (orig) break; } } catch (e) { if (!to.advice) throw e; orig = null; }
    if (to.advice) return json(await adviceEmail(to, conv, orig, note, draft, by, p.origin_url));
    if (!orig) return json({ error: "no_email", message: "This ticket has no email in hey@ to forward. Use Ask for advice instead." }, 404);
    const raw = await gm("messages/" + orig.id + "?format=raw");
    const origFrom = hdr(orig, "From"), subj = hdr(orig, "Subject") || conv.subject || "Customer message";
    const ticket = (String(p.origin_url || "").match(/^https:\/\/[a-z0-9.-]+$/i) ? p.origin_url : "https://eggsy-cx.vercel.app") + "/inbox/?c=" + cid;
    const intro = [
      "Hi " + to.name.split(" ")[0] + ",", "",
      note || "This came into hey@ and looks like one for you. Could you pick it up?", "",
      "Reply to this email and it goes straight to " + (clean(origFrom) || "the sender") + ". Eggsy has marked the ticket as forwarded to you.",
      "Forwarded from Eggsy CX by " + by + ". Ticket: " + ticket, "",
      "---------- Forwarded message ---------",
      "From: " + clean(origFrom), "Date: " + clean(hdr(orig, "Date")), "Subject: " + clean(subj), "To: " + clean(hdr(orig, "To")), "",
      textOf(orig.payload).trim(),
    ].join("\r\n");
    const boundary = "eggsy_fwd_" + crypto.randomUUID().replace(/-/g, "");
    const replyTo = clean(hdr(orig, "Reply-To") || origFrom);
    const mime = [
      "From: Lucky Egg <" + FROM + ">", "To: " + to.name + " <" + to.email + ">",
      ...(replyTo ? ["Reply-To: " + replyTo] : []),
      "Subject: " + encWord("Fwd: " + clean(subj).replace(/^(fwd?|re):\s*/i, "")),
      "MIME-Version: 1.0", 'Content-Type: multipart/mixed; boundary="' + boundary + '"', "",
      "--" + boundary, "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "", b64(enc.encode(intro)).replace(/.{1,76}/g, "$&\r\n"),
      "--" + boundary, 'Content-Type: message/rfc822; name="original-email.eml"', 'Content-Disposition: attachment; filename="original-email.eml"', "Content-Transfer-Encoding: base64", "",
      b64(fromB64Url(raw.raw)).replace(/.{1,76}/g, "$&\r\n"),
      "--" + boundary + "--", "",
    ].join("\r\n");
    const sent = await gm("messages/send", { raw: b64(enc.encode(mime)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "") });
    const first = to.name.split(" ")[0];
    await SB.from("messages").insert({ conversation_id: cid, direction: "note", author: "Forwarded to " + first,
      body: "(Forwarded to " + to.name + " by " + by + " to handle)" + (note ? " " + note : ""), sent_at: new Date().toISOString(),
      external_id: "gmail:" + sent.id, external_thread_id: sent.threadId });
    await SB.from("conversations").update({ status: "resolved", status_changed_at: new Date().toISOString(), summary: "Forwarded to " + to.name, updated_at: new Date().toISOString() }).eq("id", cid);
    return json({ ok: true, gmail: sent.id, forwarded_message: orig.id, to: to.email, mode });
  } catch (e) {
    console.error("forward-email: " + String((e as Error).message).slice(0, 160));
    return json({ error: "Could not forward from hey@" }, 502);
  }
});
