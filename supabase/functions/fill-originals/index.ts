// fill-originals: when a ticket only has Eggsy's summary of the customer's message (Wix forms, older Amazon
// imports, forwarded emails), find the customer's original email in hey@ and add it to the ticket in full.
// Called only by the database (pg_net) with the shared secret. Read-only on Gmail. Never logs email bodies.
import { createClient } from "npm:@supabase/supabase-js@2";

const SB = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const G = "https://gmail.googleapis.com/gmail/v1/users/me/";
const OWN = /@luckyegg\.co$/i;

let tok: string | null = null;
async function token() {
  if (tok) return tok;
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: Deno.env.get("GMAIL_CLIENT_ID")!, client_secret: Deno.env.get("GMAIL_CLIENT_SECRET")!, refresh_token: Deno.env.get("GMAIL_REFRESH_TOKEN")! }) });
  const j = await r.json();
  if (!r.ok || !j.access_token) throw new Error("Gmail sign-in failed (" + r.status + ")");
  return (tok = j.access_token);
}
async function gm(path: string) {
  const r = await fetch(G + path, { headers: { Authorization: "Bearer " + await token() } });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error("Gmail " + r.status);
  return j;
}
const hdr = (m: any, n: string) => (m?.payload?.headers || []).find((h: any) => h.name.toLowerCase() === n.toLowerCase())?.value || "";
const addrOf = (v: string) => (v.match(/<([^>]+)>/)?.[1] || v).trim().toLowerCase();
function b64(d: string) { try { return new TextDecoder().decode(Uint8Array.from(atob(d.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0))); } catch { return ""; } }
function htmlToText(h: string) {
  return h.replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|tr|li|h\d)>/gi, "\n")
    .replace(/<[^>]+>/g, " ").replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/&quot;/gi, '"').replace(/&#39;/gi, "'")
    .replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").replace(/[ \t]{2,}/g, " ").trim();
}
function bodyOf(p: any): string {
  if (!p) return "";
  if (p.body?.data && /^text\//.test(p.mimeType || "")) { const t = b64(p.body.data); return p.mimeType === "text/html" ? htmlToText(t) : t; }
  const parts = p.parts || [];
  const plain = parts.find((x: any) => x.mimeType === "text/plain" && x.body?.data);
  if (plain) return b64(plain.body.data);
  const html = parts.find((x: any) => x.mimeType === "text/html" && x.body?.data);
  if (html) return htmlToText(b64(html.body.data));
  for (const x of parts) { const t = bodyOf(x); if (t) return t; }
  return "";
}

// Tickets whose customer messages are all Eggsy summaries.
async function candidates(ids?: string[]) {
  let q = SB.from("conversations").select("id,origin,customer_name,customer_handle,order_number,created_at");
  if (ids?.length) q = q.in("id", ids);
  else {
    const { data: st } = await SB.from("cx_conversation_state").select("conversation_id").in("bucket", ["inbox", "waiting"]);
    q = q.in("id", (st || []).map((s: any) => s.conversation_id));
  }
  const { data: convs } = await q;
  const out: any[] = [];
  for (const c of convs || []) {
    const { data: ms } = await SB.from("messages").select("body").eq("conversation_id", c.id).eq("direction", "inbound");
    if (!ms?.length) continue;
    if (ms.every((m: any) => /^\[Summary by Eggsy/.test(m.body || ""))) out.push(c);
  }
  return out;
}

function queriesFor(c: any) {
  const email = (c.customer_handle || "").trim().toLowerCase();
  const order = (c.order_number || "").trim();
  const name = (c.customer_name || "").trim();
  const qs: string[] = [];
  if (c.origin.startsWith("amazon") && /^\d{3}-\d{7}-\d{7}$/.test(order)) qs.push('"' + order + '" from:marketplace.amazon');
  if (/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/.test(email) && !OWN.test(email)) { qs.push('"' + email + '" -from:me', email.split("@")[0] + " -from:me"); }
  if (c.origin === "wix_mmc_form" && /\S+\s+\S+/.test(name)) qs.push('"' + name.replace(/"/g, "") + '" -from:me');
  return qs;
}

async function fillOne(c: any) {
  const qs = queriesFor(c);
  if (!qs.length) return { id: c.id, result: "no way to search (no email or Amazon order number)" };
  let list: any = {};
  for (const q of qs) { list = await gm("messages?" + new URLSearchParams({ q: q + " newer_than:180d", maxResults: "10", includeSpamTrash: "true" })); if (list.messages?.length) break; }
  let added = 0;
  for (const it of list.messages || []) {
    const ext = "gmail:" + it.id;
    const { data: dupe } = await SB.from("messages").select("id").eq("external_id", ext).maybeSingle();
    if (dupe) continue;
    const m = await gm("messages/" + it.id + "?format=full");
    if ((m.labelIds || []).includes("SENT")) continue;
    if (OWN.test(addrOf(hdr(m, "From"))) && !/fwd?:/i.test(hdr(m, "Subject"))) continue;
    const body = bodyOf(m.payload).replace(/\r\n/g, "\n").trim().slice(0, 12000);
    if (!body) continue;
    const { error } = await SB.from("messages").insert({ conversation_id: c.id, direction: "inbound", author: c.customer_name || c.customer_handle || "Customer",
      body, sent_at: new Date(Number(m.internalDate || Date.now())).toISOString(), external_id: ext, external_thread_id: m.threadId });
    if (!error) added++;
  }
  return { id: c.id, result: added ? "added " + added : "nothing found in hey@" };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = req.headers.get("x-eggsy-hook") || "";
  const { data: ok } = secret ? await SB.rpc("cx_email_hook_ok", { p_secret: secret }) : { data: false };
  if (ok !== true) return new Response("Forbidden", { status: 403 });
  let p: any = {}; try { p = await req.json(); } catch { /* */ }
  try {
    const list = await candidates(Array.isArray(p.conversation_ids) ? p.conversation_ids : undefined);
    const results = [];
    for (const c of list.slice(0, 40)) { try { results.push(await fillOne(c)); } catch (e) { results.push({ id: c.id, result: "error: " + String((e as Error).message).slice(0, 80) }); } }
    console.log(JSON.stringify({ checked: list.length, filled: results.filter((r) => r.result.startsWith("added")).length }));
    return new Response(JSON.stringify({ checked: list.length, results }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("fill-originals error: " + String((e as Error).message).slice(0, 200));
    return new Response(JSON.stringify({ error: "internal" }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
