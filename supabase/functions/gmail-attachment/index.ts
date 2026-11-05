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
  if (!r.ok) throw new Error("Gmail " + r.status);
  return r.json();
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
    const m = await gm("messages/" + mid + "?format=full");
    const list: any[] = []; collect(m.payload, list);
    if (!p.attachment_id) return json({ attachments: list.map(({ data: _d, att: _a, ...a }) => a) });
    const a = list.find((x) => x.id === p.attachment_id);
    if (!a) return json({ error: "Attachment not found" }, 404);
    const data = a.data || (await gm("messages/" + mid + "/attachments/" + encodeURIComponent(a.att))).data;
    return new Response(fromB64Url(data), { headers: { ...CORS, "Content-Type": a.mimeType, "Content-Disposition": 'inline; filename="' + a.filename.replace(/"/g, "") + '"', "Cache-Control": "private, max-age=3600" } });
  } catch (e) {
    console.error("gmail-attachment: " + String((e as Error).message).slice(0, 120));
    return json({ error: "Could not load from hey@" }, 502);
  }
});
