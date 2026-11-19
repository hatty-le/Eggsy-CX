// order-address: finds the shipping address of a website (Shopify) order from the order notification
// emails in hey@, so Eggsy can prefill replacement forms even when the Shopify Admin API is not connected.
// POST { conversation_id } or { order: "11545" }  ->  { ok, address: {firstName,lastName,address1,address2,city,province,zip,country,countryCode,phone}, source }
// Signed-in Lucky Egg staff only (or the database hook secret, for checks). Read-only.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SB = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const G = "https://gmail.googleapis.com/gmail/v1/users/me/";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-eggsy-hook", "Access-Control-Allow-Methods": "POST, OPTIONS" };
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
async function gm(path: string) {
  const r = await fetch(G + path, { headers: { Authorization: "Bearer " + await token() } });
  if (!r.ok) { const e: any = new Error("Gmail " + r.status); e.status = r.status; throw e; }
  return r.json();
}
const dec = (d: string) => { try { return new TextDecoder().decode(Uint8Array.from(atob(d.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0))); } catch { return ""; } };
function partText(p: any, mime: string): string {
  if (!p) return "";
  if (p.mimeType === mime && p.body?.data) return dec(p.body.data);
  for (const c of p.parts || []) { const t = partText(c, mime); if (t) return t; }
  return "";
}
function htmlToText(h: string) {
  return h.replace(/<(script|style)[\s\S]*?<\/\1>/gi, "").replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|tr|td|li|h\d|table)>/gi, "\n")
    .replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&#39;|&rsquo;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">");
}
const COUNTRIES: Record<string, string> = { "united kingdom": "GB", "uk": "GB", "great britain": "GB", "england": "GB", "scotland": "GB", "wales": "GB", "northern ireland": "GB",
  "united states": "US", "usa": "US", "united states of america": "US", "canada": "CA", "ireland": "IE", "australia": "AU", "new zealand": "NZ", "germany": "DE", "france": "FR", "netherlands": "NL", "spain": "ES", "italy": "IT", "belgium": "BE" };
const US_STATES = /\b(A[LKZR]|C[AOT]|D[EC]|FL|GA|HI|I[ADLN]|K[SY]|LA|M[ADEINOST]|N[CDEHJMVY]|O[HKR]|PA|RI|S[CD]|T[NX]|UT|V[AT]|W[AIVY])\b/;
// Take the block under "Shipping address" and turn it into fields.
function parseAddress(text: string) {
  // Quoted replies prefix lines with ">"; HTML emails leave blank lines between table cells.
  // Gmail inserts a "<https://www.google.com/maps/search/...>" line after each address line.
  const t = text.replace(/\r/g, "").replace(/<https?:\/\/[^>\s]*>/gi, "").replace(/^[ \t>]*(?:https?:\/\/\S+)[ \t]*$/gim, "").replace(/^[ \t]*(?:>[ \t]?)+/gm, "").replace(/[ \t\u00a0\u200b]+/g, " ").replace(/\n[ \t]+/g, "\n").replace(/\n{2,}/g, "\n");
  const m = t.match(/Shipping address\s*:?\s*\n([\s\S]{5,600}?)(?:\n\s*(?:Billing address|Shipping method|Shipping|Customer|Payment|Delivery method|Order summary|View order|Contact|Subtotal|Questions|If you have)\b|$)/i);
  if (!m) return null;
  const lines = m[1].split("\n").map((l) => l.trim()).filter((l) => l && !/^shipping address/i.test(l));
  if (lines.length < 3) return null;
  let phone = "";
  const rest = lines.filter((l) => { if (/^\+?[\d ()\-]{7,}$/.test(l)) { phone = l; return false; } return true; });
  const name = rest.shift() || "";
  let country = "", countryCode = "";
  const last = (rest[rest.length - 1] || "").toLowerCase();
  if (COUNTRIES[last]) { countryCode = COUNTRIES[last]; country = rest.pop()!; }
  const cityLine = rest.pop() || "";
  let city = cityLine, province = "", zip = "";
  const us = cityLine.match(/^(.+?),?\s+([A-Z]{2})\s+(\d{5}(?:-\d{4})?)$/);
  const uk = cityLine.match(/^(.+?)\s+([A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2})$/i);
  const ca = cityLine.match(/^(.+?)\s+([A-Z]{2})\s+([A-Z]\d[A-Z]\s?\d[A-Z]\d)$/i);
  const gen = cityLine.match(/^(.+?)\s+(\S*\d\S*(?:\s\S*\d\S*)?)$/);
  if (us) { city = us[1]; province = us[2]; zip = us[3]; if (!countryCode && US_STATES.test(us[2])) countryCode = "US"; }
  else if (ca) { city = ca[1]; province = ca[2]; zip = ca[3]; countryCode = countryCode || "CA"; }
  else if (uk) { city = uk[1]; zip = uk[2].toUpperCase(); countryCode = countryCode || "GB"; }
  else if (gen) { city = gen[1]; zip = gen[2]; }
  city = city.replace(/,\s*$/, "").trim();
  // UK templates often put the county on its own line before the postcode line.
  const parts = name.trim().split(/\s+/);
  return { firstName: parts.shift() || "", lastName: parts.join(" "), address1: rest[0] || "", address2: rest.slice(1).join(", "), city, province, zip, country, countryCode, phone };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const hook = req.headers.get("x-eggsy-hook") || "";
  let allowed = false;
  if (hook) { const { data } = await SB.rpc("cx_email_hook_ok", { p_secret: hook }); allowed = data === true; }
  if (!allowed) {
    const user = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY") || "sb_publishable_gX9OKDCT6Opnt8OcsFRmiQ_xaM0O8ti", { global: { headers: { Authorization: req.headers.get("Authorization") || "" } }, auth: { persistSession: false } });
    const { data } = await user.rpc("is_lucky_egg_staff");
    allowed = data === true;
  }
  if (!allowed) return json({ error: "Forbidden" }, 403);
  let p: any = {}; try { p = await req.json(); } catch { /* */ }
  let order = String(p.order || "").replace(/^#/, "").trim();
  let email = "";
  if (!order && p.conversation_id) {
    const { data: c } = await SB.from("conversations").select("order_number,customer_handle,origin").eq("id", String(p.conversation_id)).maybeSingle();
    order = String(c?.order_number || "").replace(/^#/, "").trim();
    email = /@/.test(String(c?.customer_handle || "")) ? String(c!.customer_handle).toLowerCase() : "";
  }
  if (!/^\d{3,8}$/.test(order) && !email) return json({ ok: true, address: null, reason: "no website order number on this ticket" });
  try {
    const qs = []; const dbg: any[] = [];
    if (/^\d{3,8}$/.test(order)) qs.push('"Order #' + order + '" -in:sent', '"#' + order + '" (order OR shipped OR shipping) -in:sent');
    if (email) qs.push('"' + email + '" "Shipping address" -in:sent');
    for (const q of qs) {
      const list = await gm("messages?" + new URLSearchParams({ q: q + " newer_than:2y", maxResults: "8", includeSpamTrash: "true" }));
      for (const it of list.messages || []) {
        const msg = await gm("messages/" + it.id + "?format=full");
        const text = partText(msg.payload, "text/plain") || htmlToText(partText(msg.payload, "text/html"));
        if (order && !text.includes(order) && !String(JSON.stringify(msg.payload?.headers || [])).includes(order)) continue;
        const a = parseAddress(text);
        if (p.debug && hook) { const i = text.search(/shipping address/i); dbg.push({ q, id: it.id, has: i >= 0, around: i >= 0 ? text.slice(i, i + 500) : text.slice(0, 300), a }); }
        if (a && a.address1 && (a.zip || a.city)) {
          const subj = (msg.payload?.headers || []).find((h: any) => h.name.toLowerCase() === "subject")?.value || "";
          return json({ ok: true, address: a, source: "hey@ email: " + subj.slice(0, 120), order, ...(p.debug && hook ? { raw: text.slice(0, 3000) } : {}) });
        }
      }
    }
    return json({ ok: true, address: null, order, reason: "no order email with a shipping address found in hey@", ...(p.debug && hook ? { dbg } : {}) });
  } catch (e) {
    console.error("order-address: " + String((e as Error).message).slice(0, 160));
    return json({ ok: false, error: "Could not search hey@" }, 502);
  }
});
