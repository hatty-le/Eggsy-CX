import { createClient } from "npm:@supabase/supabase-js@2";

const SHOP = Deno.env.get("SHOPIFY_STORE_DOMAIN") || "lucky-egg-ltd.myshopify.com";
const API = "2025-10";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_KEY);

const cors = {
  "Access-Control-Allow-Origin": "https://eggsy-cx.vercel.app",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-eggsy-hook",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: cors });
}

type Staff = { email: string; jwt: string; hook: boolean };

async function authorize(req: Request): Promise<Staff | Response> {
  const hook = req.headers.get("x-eggsy-hook") || "";
  if (hook) {
    const { data, error } = await admin.rpc("cx_email_hook_ok", { p_secret: hook });
    if (error || !data) return json({ ok: false, error: "unauthorized" }, 401);
    return { email: "hook", jwt: "", hook: true };
  }
  const auth = req.headers.get("Authorization") || "";
  const jwt = auth.replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return json({ ok: false, error: "unauthorized" }, 401);
  const userSb = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
  const { data, error } = await userSb.auth.getUser();
  const email = (data?.user?.email || "").toLowerCase();
  if (error || !email.endsWith("@luckyegg.co")) return json({ ok: false, error: "unauthorized" }, 401);
  return { email, jwt, hook: false };
}

async function shopifyToken(): Promise<string | null> {
  const env = Deno.env.get("SHOPIFY_ADMIN_ACCESS_TOKEN");
  if (env) return env;
  const { data, error } = await admin.rpc("cx_shopify_admin_token");
  if (error || !data) return null;
  return String(data);
}

async function shopify(query: string, variables: Record<string, unknown> = {}) {
  const token = await shopifyToken();
  if (!token) return { ok: false as const, error: "not_configured", userErrors: [] as { message: string }[] };
  const res = await fetch(`https://${SHOP}/admin/api/${API}/graphql.json`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": token },
    body: JSON.stringify({ query, variables }),
  });
  const body = await res.json();
  if (!res.ok || body.errors) {
    const msg = (body.errors || []).map((e: { message: string }) => e.message).join("; ") || `Shopify HTTP ${res.status}`;
    return { ok: false as const, error: msg, userErrors: [] as { message: string }[] };
  }
  return { ok: true as const, data: body.data };
}

function countryCode(v: string) {
  const s = (v || "").trim().toUpperCase();
  if (/^[A-Z]{2}$/.test(s)) return s;
  const map: Record<string, string> = {
    "UNITED KINGDOM": "GB", UK: "GB", "GREAT BRITAIN": "GB", ENGLAND: "GB", SCOTLAND: "GB", WALES: "GB",
    "UNITED STATES": "US", USA: "US", "UNITED STATES OF AMERICA": "US",
    GERMANY: "DE", DEUTSCHLAND: "DE", FRANCE: "FR", CANADA: "CA", IRELAND: "IE",
    AUSTRALIA: "AU", SPAIN: "ES", ITALY: "IT", NETHERLANDS: "NL", BELGIUM: "BE",
    AUSTRIA: "AT", SWEDEN: "SE", POLAND: "PL",
  };
  return map[s] || s.slice(0, 2) || "GB";
}

function addrInput(a: Record<string, string> = {}) {
  return {
    firstName: a.firstName || a.first_name || "",
    lastName: a.lastName || a.last_name || "",
    address1: a.address1 || "",
    address2: a.address2 || "",
    city: a.city || "",
    province: a.province || a.provinceCode || "",
    zip: a.zip || "",
    countryCode: countryCode(a.countryCode || a.countryCodeV2 || a.country || "GB"),
    phone: a.phone || "",
    company: a.company || "",
  };
}

function fmtAddr(a: Record<string, string>) {
  return [a.firstName, a.lastName].filter(Boolean).join(" ") + ", " +
    [a.address1, a.address2, a.city, a.province, a.zip, a.countryCode || a.country].filter(Boolean).join(", ");
}

async function staffClient(staff: Staff) {
  return createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${staff.jwt}` } },
  });
}

async function logNote(staff: Staff, conversationId: string, body: string, ext?: string) {
  const sb = await staffClient(staff);
  await sb.rpc("cx_log_action_note", {
    p_conversation_id: conversationId,
    p_body: body,
    p_external_id: ext || null,
  });
}

async function loadConversation(id: string) {
  const { data, error } = await admin.from("conversations").select("id,origin,shop,order_number,customer_name,customer_handle,external_id").eq("id", id).maybeSingle();
  if (error || !data) return null;
  return data;
}

const SEARCH_Q = `query Search($q: String!) {
  products(first: 25, query: $q) {
    nodes {
      title status
      variants(first: 30) { nodes { id title sku price } }
    }
  }
}`;

const ORDER_LOOKUP = `query Lookup($q: String!) {
  orders(first: 8, query: $q) {
    nodes {
      id name createdAt email displayFinancialStatus displayFulfillmentStatus
      currentTotalPriceSet { shopMoney { amount currencyCode } }
      shippingAddress { firstName lastName address1 address2 city province provinceCode zip country countryCodeV2 phone company }
      lineItems(first: 50) {
        nodes {
          id title sku quantity refundableQuantity
          variant { id }
          originalUnitPriceSet { shopMoney { amount currencyCode } }
        }
      }
    }
  }
}`;

const ORDER_GET = `query Get($id: ID!) {
  order(id: $id) {
    id name displayFinancialStatus displayFulfillmentStatus
    currentTotalPriceSet { shopMoney { amount currencyCode } }
    transactions(first: 20) { id kind status gateway amountSet { shopMoney { amount currencyCode } } }
    lineItems(first: 50) { nodes { id title sku quantity refundableQuantity } }
    fulfillments(first: 10) {
      status
      trackingInfo { number url company }
    }
    fulfillmentOrders(first: 8) {
      nodes { id status assignedLocation { name } }
    }
  }
}`;

const DRAFT_CREATE = `mutation DraftCreate($input: DraftOrderInput!) {
  draftOrderCreate(input: $input) {
    draftOrder { id name totalPrice presentmentCurrencyCode }
    userErrors { field message }
  }
}`;

const DRAFT_COMPLETE = `mutation DraftComplete($id: ID!) {
  draftOrderComplete(id: $id, paymentPending: false) {
    draftOrder {
      id
      order {
        id name displayFinancialStatus
        fulfillmentOrders(first: 8) { nodes { id status assignedLocation { name } } }
      }
    }
    userErrors { field message }
  }
}`;

const DRAFT_DELETE = `mutation DraftDelete($id: ID!) {
  draftOrderDelete(input: { id: $id }) {
    deletedId
    userErrors { field message }
  }
}`;

const REFUND_CREATE = `mutation Refund($input: RefundInput!) {
  refundCreate(input: $input) {
    refund { id totalRefundedSet { shopMoney { amount currencyCode } } }
    userErrors { field message }
  }
}`;

function orderSearchQuery(raw: string) {
  const n = (raw || "").trim().replace(/^#/, "");
  if (!n) return "";
  if (/^\d+$/.test(n)) return `name:#${n}`;
  return `name:${n}`;
}

async function searchProducts(q: string) {
  const token = await shopifyToken();
  if (!token) return { ok: false, error: "not_configured", products: [] };
  const query = (q || "").trim() ? `${q.trim()} status:active` : "status:active";
  const res = await shopify(SEARCH_Q, { q: query });
  if (!res.ok) return { ok: false, error: res.error, products: [] };
  const products = (res.data.products?.nodes || []).map((p: { title: string; variants: { nodes: { id: string; title: string; sku: string; price: string }[] } }) => ({
    title: p.title,
    variants: (p.variants?.nodes || []).map((v) => ({
      id: v.id,
      title: v.title,
      sku: v.sku,
      price: v.price,
      label: p.title + (v.title && v.title !== "Default Title" ? ` · ${v.title}` : "") + (v.sku ? ` (${v.sku})` : ""),
    })),
  }));
  return { ok: true, products };
}

async function lookupOrder(conversationId: string, name?: string) {
  const conv = await loadConversation(conversationId);
  const q = orderSearchQuery(name || conv?.order_number || "");
  const token = await shopifyToken();
  if (!token) return { ok: false, error: "not_configured", order: null, conversation: conv };
  if (!q) return { ok: true, order: null, conversation: conv };
  const res = await shopify(ORDER_LOOKUP, { q });
  if (!res.ok) return { ok: false, error: res.error, order: null, conversation: conv };
  const nodes = res.data.orders?.nodes || [];
  return { ok: true, order: nodes[0] || null, orders: nodes, conversation: conv };
}

function routingWarning(country: string, location: string) {
  const cc = countryCode(country);
  const loc = (location || "").toLowerCase();
  if (!loc) return null;
  if (cc === "US" && loc.includes("finishing line")) {
    return "This US address was assigned to The Finishing Line (UK). Web checkout orders to the US usually go to Forceget East or West Coast. Check the fulfilment location before the 3PL ships.";
  }
  if (cc === "GB" && loc.includes("forceget")) {
    return "This UK address was assigned to a Forceget warehouse. Web checkout orders in the UK usually go to The Finishing Line.";
  }
  return null;
}

async function previewOrCreateReplacement(body: Record<string, unknown>, staff: Staff) {
  const conversationId = String(body.conversation_id || "");
  const items = (body.items as { variantId?: string; title?: string; sku?: string; quantity?: number; price?: string }[]) || [];
  const address = addrInput((body.address || {}) as Record<string, string>);
  const reason = String(body.reason || "").trim();
  const dryRun = body.dry_run !== false && body.dry_run !== undefined ? !!body.dry_run : !body.create;
  const create = !!body.create && !dryRun;
  const conv = await loadConversation(conversationId);
  if (!conv) return json({ ok: false, error: "conversation not found" }, 400);
  if (!items.length) return json({ ok: false, error: "Pick at least one product or part." }, 400);
  if (!address.address1 || !address.city || !address.zip || !address.countryCode) {
    return json({ ok: false, error: "A full shipping address is needed (line, city, postcode and country)." }, 400);
  }
  const retail = items.reduce((s, it) => s + (parseFloat(it.price || "0") || 0) * (it.quantity || 1), 0);
  const tags = ["eggsy-replacement", `cx-${conversationId}`];
  const note = [
    "Eggsy CX replacement",
    `ticket https://eggsy-cx.vercel.app/inbox/?c=${conversationId}`,
    conv.origin ? `channel ${conv.origin}` : "",
    conv.order_number ? `original order ${conv.order_number}` : "",
    reason ? `reason: ${reason}` : "",
    `created by ${staff.email}`,
  ].filter(Boolean).join(" · ");
  const lineItems = items.map((it) => ({
    variantId: it.variantId,
    quantity: it.quantity || 1,
  }));
  const draftInput = {
    note,
    tags,
    taxExempt: true,
    useCustomerDefaultAddress: false,
    shippingAddress: address,
    billingAddress: address,
    lineItems,
    shippingLine: { title: "Replacement — no charge", price: "0.00" },
    appliedDiscount: { title: "CX replacement", description: "Free replacement from Eggsy CX", value: 100.0, valueType: "PERCENTAGE" },
  };
  const payload = { shop: SHOP, tags, note, address, items, reason, retail_value: retail, source_origin: conv.origin, source_order: conv.order_number };

  if (!create) {
    return json({ ok: true, dry_run: true, would_create: payload, shopify_connected: !!(await shopifyToken()) });
  }

  const token = await shopifyToken();
  if (!token) {
    return json({
      ok: false,
      error: "not_configured",
      message: "Shopify Admin API is not connected to Eggsy CX yet, so a live order was not created. You can create the £0 order in Shopify Admin with these tags and this note, then record the order number here.",
      would_create: payload,
    }, 409);
  }

  const created = await shopify(DRAFT_CREATE, { input: draftInput });
  if (!created.ok) return json({ ok: false, error: created.error }, 502);
  const draftErrs = created.data.draftOrderCreate?.userErrors || [];
  if (draftErrs.length) return json({ ok: false, error: draftErrs.map((e: { message: string }) => e.message).join("; ") }, 400);
  const draft = created.data.draftOrderCreate.draftOrder;
  const completed = await shopify(DRAFT_COMPLETE, { id: draft.id });
  if (!completed.ok) {
    await shopify(DRAFT_DELETE, { id: draft.id });
    return json({ ok: false, error: completed.error }, 502);
  }
  const completeErrs = completed.data.draftOrderComplete?.userErrors || [];
  if (completeErrs.length) {
    await shopify(DRAFT_DELETE, { id: draft.id });
    return json({ ok: false, error: completeErrs.map((e: { message: string }) => e.message).join("; ") }, 400);
  }
  const order = completed.data.draftOrderComplete?.draftOrder?.order;
  if (!order) {
    await shopify(DRAFT_DELETE, { id: draft.id });
    return json({ ok: false, error: "Shopify completed the draft but did not return an order." }, 502);
  }
  const loc = order?.fulfillmentOrders?.nodes?.[0]?.assignedLocation?.name || "";
  const warn = routingWarning(address.countryCode, loc);
  const details = {
    ...payload,
    assigned_location: loc,
    routing_warning: warn,
    financial_status: order?.displayFinancialStatus,
  };
  const sb = await staffClient(staff);
  const { data: row, error } = await sb.from("cx_actions").insert({
    conversation_id: conversationId,
    type: "replacement",
    status: "created",
    details,
    shopify_order_id: order.id,
    shopify_order_name: order.name,
    created_by: staff.email,
  }).select("*").single();
  if (error) return json({ ok: false, error: error.message, order }, 500);
  await logNote(
    staff,
    conversationId,
    `Replacement order ${order.name} created in Shopify (no charge) for ${items.map((i) => `${i.title || i.variantId} × ${i.quantity || 1}`).join(", ")}, shipping to ${fmtAddr(address)}. Assigned to ${loc || "Shopify’s default location"}.${warn ? " Warning: " + warn : ""}`,
    `note:action:${row.id}`,
  );
  return json({ ok: true, dry_run: false, action: row, order, routing_warning: warn });
}

async function createRefund(body: Record<string, unknown>, staff: Staff) {
  const conversationId = String(body.conversation_id || "");
  const conv = await loadConversation(conversationId);
  if (!conv) return json({ ok: false, error: "conversation not found" }, 400);
  const dryRun = !!body.dry_run || !body.create;
  const create = !!body.create && !dryRun;
  const restock = !!body.restock;
  const notify = body.notify !== false;
  const orderId = String(body.shopify_order_id || "");
  if (!orderId) return json({ ok: false, error: "No Shopify order is linked. Use the manual refund path for marketplace orders." }, 400);
  const token = await shopifyToken();
  if (!token) {
    return json({ ok: false, error: "not_configured", message: "Shopify Admin API is not connected to Eggsy CX yet, so a live refund was not created." }, 409);
  }
  const got = await shopify(ORDER_GET, { id: orderId });
  if (!got.ok || !got.data.order) return json({ ok: false, error: got.error || "Shopify order not found" }, 404);
  const order = got.data.order;
  const parent = (order.transactions || []).find((t: { kind: string; status: string }) => t.kind === "SALE" && t.status === "SUCCESS")
    || (order.transactions || []).find((t: { kind: string; status: string }) => t.kind === "CAPTURE" && t.status === "SUCCESS");
  const fullAmount = order.currentTotalPriceSet?.shopMoney?.amount || "0.00";
  const currency = order.currentTotalPriceSet?.shopMoney?.currencyCode || "GBP";
  const amount = String(body.amount || fullAmount);
  const refundLineItems = restock
    ? (order.lineItems?.nodes || [])
      .filter((li: { refundableQuantity: number }) => li.refundableQuantity > 0)
      .map((li: { id: string; refundableQuantity: number }) => ({
        lineItemId: li.id,
        quantity: li.refundableQuantity,
        restockType: "RETURN",
      }))
    : [];
  const input: Record<string, unknown> = {
    orderId,
    note: `Eggsy CX refund · ticket ${conversationId}` + (body.reason ? ` · ${body.reason}` : ""),
    notify,
    refundLineItems,
  };
  if (parent) {
    input.transactions = [{ parentId: parent.id, amount, kind: "REFUND", gateway: parent.gateway }];
  }
  if (dryRun || !create) {
    return json({ ok: true, dry_run: true, would_refund: { order: order.name, amount, currency, restock, notify, input_note: input.note } });
  }
  if (!body.confirm) return json({ ok: false, error: "confirm_required", message: "Confirm the refund before it is created." }, 400);
  const res = await shopify(REFUND_CREATE, { input });
  if (!res.ok) return json({ ok: false, error: res.error }, 502);
  const out = res.data.refundCreate;
  const errs = out?.userErrors || [];
  if (errs.length) return json({ ok: false, error: errs.map((e: { message: string }) => e.message).join("; ") }, 400);
  const refund = out.refund;
  const refunded = refund?.totalRefundedSet?.shopMoney;
  const sb = await staffClient(staff);
  const { data: row, error } = await sb.from("cx_actions").insert({
    conversation_id: conversationId,
    type: "refund",
    status: "done",
    details: {
      amount: refunded?.amount || amount,
      amount_currency: refunded?.currencyCode || currency,
      restock,
      notify,
      reason: body.reason || "",
      shopify_order_name: order.name,
      shopify_order_id: order.id,
      source_origin: conv.origin,
    },
    shopify_order_id: order.id,
    shopify_order_name: order.name,
    shopify_refund_id: refund?.id,
    created_by: staff.email,
    completed_at: new Date().toISOString(),
  }).select("*").single();
  if (error) return json({ ok: false, error: error.message, refund }, 500);
  await logNote(
    staff,
    conversationId,
    `Refund of ${refunded?.amount || amount} ${refunded?.currencyCode || currency} recorded on Shopify order ${order.name}${restock ? " (restocked)" : ""}.`,
    `note:action:${row.id}`,
  );
  return json({ ok: true, dry_run: false, action: row, refund });
}

async function refreshTracking(conversationId?: string) {
  const q = admin.from("cx_actions").select("*").eq("type", "replacement").eq("status", "created").not("shopify_order_id", "is", null);
  if (conversationId) q.eq("conversation_id", conversationId);
  const { data: rows, error } = await q.limit(50);
  if (error) return { ok: false, error: error.message, updated: 0 };
  const token = await shopifyToken();
  if (!token) return { ok: true, updated: 0, skipped: "not_configured" };
  let updated = 0;
  for (const row of rows || []) {
    const got = await shopify(ORDER_GET, { id: row.shopify_order_id });
    if (!got.ok || !got.data.order) continue;
    const order = got.data.order;
    const infos = (order.fulfillments || []).flatMap((f: { trackingInfo: { number?: string; url?: string; company?: string }[] }) => f.trackingInfo || []);
    const info = infos.find((t: { number?: string }) => t.number) || infos[0];
    const loc = order.fulfillmentOrders?.nodes?.[0]?.assignedLocation?.name || row.details?.assigned_location;
    const next: Record<string, unknown> = {
      details: { ...(row.details || {}), assigned_location: loc, fulfillment_status: order.displayFulfillmentStatus },
      updated_at: new Date().toISOString(),
    };
    if (info?.number) {
      next.tracking_number = info.number;
      next.tracking_url = info.url || null;
      next.tracking_company = info.company || null;
      if (order.displayFulfillmentStatus === "FULFILLED") {
        next.status = "done";
        next.completed_at = new Date().toISOString();
      }
    }
    const { error: upErr } = await admin.from("cx_actions").update(next).eq("id", row.id);
    if (upErr) continue;
    if (info?.number && info.number !== row.tracking_number) {
      await admin.from("messages").insert({
        conversation_id: row.conversation_id,
        direction: "note",
        author: "Eggsy CX",
        body: `Replacement ${row.shopify_order_name || order.name} now has tracking ${info.company ? info.company + " " : ""}${info.number}${info.url ? " · " + info.url : ""}.`,
        sent_at: new Date().toISOString(),
        external_id: `note:action-track:${row.id}:${info.number}`,
      });
    }
    updated++;
  }
  return { ok: true, updated };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { body = {}; }
  const staff = await authorize(req);
  if (staff instanceof Response) return staff;
  const action = String(body.action || body.mode || "");
  if (staff.hook && action !== "refresh_tracking") return json({ ok: false, error: "unauthorized" }, 401);
  try {
    if (action === "status" || action === "connected") {
      return json({ ok: true, shopify_connected: !!(await shopifyToken()), shop: SHOP });
    }
    if (action === "search_products") return json(await searchProducts(String(body.q || "")));
    if (action === "lookup_order") return json(await lookupOrder(String(body.conversation_id || ""), body.name ? String(body.name) : undefined));
    if (action === "replacement") return await previewOrCreateReplacement(body, staff);
    if (action === "refund") return await createRefund(body, staff);
    if (action === "refresh_tracking") {
      const out = await refreshTracking(body.conversation_id ? String(body.conversation_id) : undefined);
      return json(out);
    }
    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: e instanceof Error ? e.message : "unexpected error" }, 500);
  }
});
