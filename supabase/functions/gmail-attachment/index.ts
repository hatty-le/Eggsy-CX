// gmail-attachment: lets signed-in Lucky Egg staff view the photos and files a customer attached to an email in hey@.
// POST { message_id }                 -> { attachments: [{ id, filename, mimeType, size }] }
// POST { message_id, attachment_id }  -> the file itself
// Only works for emails already stored on an Eggsy CX ticket (messages.external_id = 'gmail:<id>'). Read-only.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SB = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const G = "https://gmail.googleapis.com/gmail/v1/users/me/";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };

let tok: string | null = null;
async function token() {
  if (tok) return tok;
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: Deno.env.get("GMAIL_CLIENT_ID")!, client_secret: Deno.env.get("GMAIL_CLIENT_SECRET")!, refresh_token: Deno.env.get("GMAIL_REFRESH_TOKEN")! }) });
  const j = await r.json();
  if (!r.ok || !j.access_token) throw new Error("Gmail sign-in failed");
  return (tok = j.access_token);
}
async function gm(path: string) {
  const r = await fetch(G + path, { headers: { Authorization: "Bearer " + await token() } });
  if (!r.ok) { const e: any = new Error("Gmail " + r.status); e.status = r.status; throw e; }
  return r.json();
}
// Older tickets (imported by Grok before 5 Nov) carry Gmail ids from a different mailbox view, so hey@ returns 404.
// Find the same email in hey@ by sender and time, and repair the stored id so it works directly next time.
async function resolve(mid: string, rowId: string) {
  try { return { id: mid, msg: await gm("messages/" + mid + "?format=full") }; } catch (e) { if (![400, 404].includes((e as any).status)) throw e; }
  const { data: row } = await SB.from("messages").select("sent_at, conversation_id, conversations(customer_handle)").eq("id", rowId).maybeSingle();
  const email = String((row as any)?.conversations?.customer_handle || "").trim().toLowerCase();
  if (!row || !email.includes("@")) return null;
  const t = Math.floor(Date.parse((row as any).sent_at) / 1000);
  const list = await gm("messages?" + new URLSearchParams({ q: 'from:"' + email + '" after:' + (t - 900) + " before:" + (t + 900), maxResults: "5", includeSpamTrash: "true" }));
  for (const it of list.messages || []) {
    const msg = await gm("messages/" + it.id + "?format=full");
    const { data: taken } = await SB.from("messages").select("id").eq("external_id", "gmail:" + it.id).maybeSingle();
    if (!taken) await SB.from("messages").update({ external_id: "gmail:" + it.id, external_thread_id: msg.threadId }).eq("id", rowId);
    return { id: it.id, msg };
  }
  return null;
}
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// Attachments are identified by MIME part id: Gmail's own attachment ids change on every fetch.
function collect(p: any, out: any[]) {
  if (!p) return;
  if (p.filename && (p.body?.attachmentId || p.body?.data)) {
    out.push({ id: "part:" + p.partId, att: p.body.attachmentId || null, filename: p.filename, mimeType: p.mimeType || "application/octet-stream", size: p.body.size || 0, data: p.body.data || null });
  }
  for (const c of p.parts || []) collect(c, out);
}
function fromB64Url(d: string) { const s = atob(d.replace(/-/g, "+").replace(/_/g, "/")); return Uint8Array.from(s, (c) => c.charCodeAt(0)); }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  // Signed-in staff only.
  const auth = req.headers.get("Authorization") || "";
  const user = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY") || "sb_publishable_gX9OKDCT6Opnt8OcsFRmiQ_xaM0O8ti", { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: staff } = await user.rpc("is_lucky_egg_staff");
  if (staff !== true) return json({ error: "Forbidden" }, 403);

  let p: any = {}; try { p = await req.json(); } catch { /* */ }
  const mid = String(p.message_id || "").replace(/^gmail:/, "");
  if (!/^[0-9a-f]{8,32}$/i.test(mid)) return json({ error: "Bad message id" }, 400);
  // Only emails that are on a ticket.
  const { data: row } = await SB.from("messages").select("id").eq("external_id", "gmail:" + mid).maybeSingle();
  if (!row) return json({ error: "Not on a ticket" }, 404);
  try {
    const found = await resolve(mid, row.id);
    if (!found) return json({ attachments: [], note: "This email could not be found in hey@" });
    const m = found.msg;
    const list: any[] = []; collect(m.payload, list);
    if (!p.attachment_id) return json({ message_id: "gmail:" + found.id, attachments: list.map(({ data: _d, att: _a, ...a }) => a) });
    const a = list.find((x) => x.id === p.attachment_id);
    if (!a) return json({ error: "Attachment not found" }, 404);
    const data = a.data || (await gm("messages/" + found.id + "/attachments/" + encodeURIComponent(a.att))).data;
    return new Response(fromB64Url(data), { headers: { ...CORS, "Content-Type": a.mimeType, "Content-Disposition": 'inline; filename="' + a.filename.replace(/"/g, "") + '"', "Cache-Control": "private, max-age=3600" } });
  } catch (e) {
    console.error("gmail-attachment: " + String((e as Error).message).slice(0, 120));
    return json({ error: "Could not load from hey@" }, 502);
  }
});
