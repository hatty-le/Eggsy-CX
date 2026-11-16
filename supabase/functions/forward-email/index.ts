// forward-email: lets signed-in Lucky Egg staff forward a customer email from hey@ to a colleague (e.g. sales).
// POST { conversation_id, to: "claudia-bb", note? } -> { ok, gmail, forwarded_message }
// Recipients are a fixed allow-list here, so this can never forward to an outside address.
// The colleague's reply goes straight to the original sender (Reply-To). hey@ is not copied, so the forward never comes back in as a new ticket.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SB = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const G = "https://gmail.googleapis.com/gmail/v1/users/me/";
const FROM = "hey@luckyegg.co";
const RECIPIENTS: Record<string, { email: string; name: string }> = {
  "claudia-bb": { email: "claudia.bb@luckyegg.co", name: "Claudia Bettson-Burdett" },
};
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
  const to = RECIPIENTS[String(p.to || "")];
  if (!to) return json({ error: "Unknown recipient" }, 400);
  const cid = String(p.conversation_id || "");
  if (!/^[0-9a-f-]{36}$/i.test(cid)) return json({ error: "Bad conversation id" }, 400);
  const note = String(p.note || "").slice(0, 4000).trim();

  const { data: conv } = await SB.from("conversations").select("id,customer_name,customer_handle,subject,order_number,overview").eq("id", cid).maybeSingle();
  if (!conv) return json({ error: "Ticket not found" }, 404);
  const { data: rows } = await SB.from("messages").select("id,external_id,sent_at").eq("conversation_id", cid).eq("direction", "inbound").like("external_id", "gmail:%").order("sent_at", { ascending: false }).limit(3);
  const handle = String(conv.customer_handle || "").trim().toLowerCase();
  try {
    let orig: any = null;
    for (const r of rows || []) { orig = await resolve(String(r.external_id).slice(6), r, handle); if (orig) break; }
    if (!orig) return json({ error: "no_email", message: "This ticket has no email in hey@ to forward." }, 404);
    const raw = await gm("messages/" + orig.id + "?format=raw");
    const origFrom = hdr(orig, "From"), subj = hdr(orig, "Subject") || conv.subject || "Customer message";
    const ticket = (String(p.origin_url || "").match(/^https:\/\/[a-z0-9.-]+$/i) ? p.origin_url : "https://eggsy-cx.vercel.app") + "/inbox/?c=" + cid;
    const intro = [
      "Hi " + to.name.split(" ")[0] + ",", "",
      note || "This came into hey@ and looks like one for sales. Could you pick it up?", "",
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
    return json({ ok: true, gmail: sent.id, forwarded_message: orig.id, to: to.email });
  } catch (e) {
    console.error("forward-email: " + String((e as Error).message).slice(0, 160));
    return json({ error: "Could not forward from hey@" }, 502);
  }
});
