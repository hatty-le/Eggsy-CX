import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CLIENT_CREDENTIAL_SKEW_MS,
  clientCredentialFailure,
  createShopifyTokenStore,
  scrubSecrets,
  type ShopifyTokenDeps,
  type VaultClientCredentials,
} from "../functions/cx-actions/shopify-token.ts";

const SHOP = "lucky-egg-ltd.myshopify.com";
const CLIENT_ID = "client-id-abc12345";
const CLIENT_SECRET = "client-secret-xyz98765";

function emptyVault(): VaultClientCredentials {
  return { clientId: null, clientSecret: null, error: null };
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function tokenResponse(token: string, expiresIn = 86399): Response {
  return jsonResponse(200, { access_token: token, scope: "read_orders", expires_in: expiresIn });
}

type Harness = {
  deps: ShopifyTokenDeps;
  calls: { url: string; init: RequestInit | undefined }[];
  env: Record<string, string | undefined>;
  vaultAdmin: () => Promise<string | null>;
  vaultClient: () => Promise<VaultClientCredentials>;
  vaultAdminCalls: number;
  vaultClientCalls: number;
  setNow: (value: number) => void;
  advance: (ms: number) => void;
};

function harness(opts?: {
  env?: Record<string, string | undefined>;
  vaultAdmin?: () => Promise<string | null>;
  vaultClient?: () => Promise<VaultClientCredentials>;
  fetchImpl?: ShopifyTokenDeps["fetchImpl"];
}): Harness {
  let now = 1_700_000_000_000;
  const calls: Harness["calls"] = [];
  const env = { ...(opts?.env || {}) };
  let vaultAdminCalls = 0;
  let vaultClientCalls = 0;
  const vaultAdmin = opts?.vaultAdmin || (async () => null);
  const vaultClient = opts?.vaultClient || (async () => emptyVault());
  const fetchImpl: ShopifyTokenDeps["fetchImpl"] = opts?.fetchImpl || (async (url, init) => {
    calls.push({ url: String(url), init });
    return tokenResponse("shpat_cachedtoken");
  });
  const deps: ShopifyTokenDeps = {
    shop: SHOP,
    readEnv: (name) => env[name],
    readVaultAdminToken: async () => {
      vaultAdminCalls += 1;
      return vaultAdmin();
    },
    readVaultClientCredentials: async () => {
      vaultClientCalls += 1;
      return vaultClient();
    },
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      if (opts?.fetchImpl) {
        calls.pop();
        return opts.fetchImpl(url, init);
      }
      return tokenResponse("shpat_cachedtoken");
    },
    now: () => now,
  };
  if (opts?.fetchImpl) {
    const custom = opts.fetchImpl;
    deps.fetchImpl = async (url, init) => {
      calls.push({ url: String(url), init });
      return custom(url, init);
    };
  }
  return {
    deps,
    calls,
    env,
    vaultAdmin,
    vaultClient,
    get vaultAdminCalls() { return vaultAdminCalls; },
    get vaultClientCalls() { return vaultClientCalls; },
    setNow: (value) => { now = value; },
    advance: (ms) => { now += ms; },
  };
}

function silenceConsole() {
  const methods = ["log", "info", "warn", "error", "debug"] as const;
  const originals = new Map<string, (...args: unknown[]) => void>();
  const seen: unknown[][] = [];
  for (const method of methods) {
    originals.set(method, console[method] as (...args: unknown[]) => void);
    console[method] = (...args: unknown[]) => { seen.push(args); };
  }
  return {
    seen,
    restore() {
      for (const method of methods) console[method] = originals.get(method)!;
    },
  };
}

test("static edge token is used and client credentials are not requested", async () => {
  const h = harness({ env: { SHOPIFY_ADMIN_ACCESS_TOKEN: "  shpat_statictoken  " } });
  const store = createShopifyTokenStore(h.deps);
  const got = await store.get();
  assert.equal(got.token, "shpat_statictoken");
  assert.equal(got.source, "static");
  assert.equal(got.error, null);
  assert.equal(h.calls.length, 0);
  assert.equal(h.vaultAdminCalls, 0);
  assert.equal(h.vaultClientCalls, 0);
});

test("vault static token is used when the edge secret is unset", async () => {
  const h = harness({ vaultAdmin: async () => "shpat_fromvault" });
  const store = createShopifyTokenStore(h.deps);
  const got = await store.get();
  assert.equal(got.token, "shpat_fromvault");
  assert.equal(got.source, "static");
  assert.equal(h.calls.length, 0);
  assert.equal(h.vaultClientCalls, 0);
});

test("blank static token falls through to client credentials", async () => {
  const h = harness({
    env: { SHOPIFY_ADMIN_ACCESS_TOKEN: "   ", SHOPIFY_CLIENT_ID: CLIENT_ID, SHOPIFY_CLIENT_SECRET: CLIENT_SECRET },
  });
  const store = createShopifyTokenStore(h.deps);
  const got = await store.get();
  assert.equal(got.source, "client_credentials");
  assert.equal(h.calls.length, 1);
});

test("client credentials grant posts the documented form body and caches until the skew window", async () => {
  const h = harness({
    env: { SHOPIFY_CLIENT_ID: CLIENT_ID, SHOPIFY_CLIENT_SECRET: CLIENT_SECRET },
    fetchImpl: async () => tokenResponse("shpat_granted", 1000),
  });
  const logs = silenceConsole();
  const store = createShopifyTokenStore(h.deps);
  try {
    const first = await store.get();
    const second = await store.get();
    assert.equal(first.token, "shpat_granted");
    assert.equal(first.error, null);
    assert.equal(second.token, "shpat_granted");
    assert.equal(h.calls.length, 1);
    assert.equal(h.vaultClientCalls, 0);
    const call = h.calls[0];
    assert.equal(call.url, `https://${SHOP}/admin/oauth/access_token`);
    assert.equal(call.init?.method, "POST");
    const headers = new Headers(call.init?.headers);
    assert.equal(headers.get("content-type"), "application/x-www-form-urlencoded");
    const params = new URLSearchParams(String(call.init?.body));
    assert.equal(params.get("grant_type"), "client_credentials");
    assert.equal(params.get("client_id"), CLIENT_ID);
    assert.equal(params.get("client_secret"), CLIENT_SECRET);
    assert.equal(params.has("scope"), false);
    assert.deepEqual(logs.seen, []);
    h.advance(1000 * 1000 - CLIENT_CREDENTIAL_SKEW_MS - 1);
    await store.get();
    assert.equal(h.calls.length, 1);
    h.advance(2);
    await store.get();
    assert.equal(h.calls.length, 2);
  } finally {
    logs.restore();
  }
});

test("parallel reads share one token request", async () => {
  let release: (value: Response) => void = () => {};
  const gate = new Promise<Response>((resolve) => { release = resolve; });
  const h = harness({
    env: { SHOPIFY_CLIENT_ID: CLIENT_ID, SHOPIFY_CLIENT_SECRET: CLIENT_SECRET },
    fetchImpl: () => gate,
  });
  const store = createShopifyTokenStore(h.deps);
  const a = store.get();
  const b = store.get();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(h.calls.length, 1);
  release(tokenResponse("shpat_shared"));
  const [ra, rb] = await Promise.all([a, b]);
  assert.equal(ra.token, "shpat_shared");
  assert.equal(rb.token, "shpat_shared");
  assert.equal(h.calls.length, 1);
});

test("force refresh and invalidate request a new token", async () => {
  let n = 0;
  const h = harness({
    env: { SHOPIFY_CLIENT_ID: CLIENT_ID, SHOPIFY_CLIENT_SECRET: CLIENT_SECRET },
    fetchImpl: async () => tokenResponse(`shpat_token${++n}`),
  });
  const store = createShopifyTokenStore(h.deps);
  assert.equal((await store.get()).token, "shpat_token1");
  store.invalidate();
  assert.equal((await store.get({ forceRefresh: true })).token, "shpat_token2");
  assert.equal(h.calls.length, 2);
});

test("vault client credentials are used when edge secrets are unset", async () => {
  const h = harness({
    vaultClient: async () => ({ clientId: CLIENT_ID, clientSecret: CLIENT_SECRET, error: null }),
    fetchImpl: async () => tokenResponse("shpat_fromvaultcreds"),
  });
  const store = createShopifyTokenStore(h.deps);
  const got = await store.get();
  assert.equal(got.token, "shpat_fromvaultcreds");
  assert.equal(h.vaultClientCalls, 1);
  const params = new URLSearchParams(String(h.calls[0].init?.body));
  assert.equal(params.get("client_id"), CLIENT_ID);
  assert.equal(params.get("client_secret"), CLIENT_SECRET);
});

test("edge client id fills from vault when only the secret is in the environment", async () => {
  const h = harness({
    env: { SHOPIFY_CLIENT_SECRET: CLIENT_SECRET },
    vaultClient: async () => ({ clientId: CLIENT_ID, clientSecret: null, error: null }),
    fetchImpl: async () => tokenResponse("shpat_mixed"),
  });
  const store = createShopifyTokenStore(h.deps);
  assert.equal((await store.get()).token, "shpat_mixed");
  const params = new URLSearchParams(String(h.calls[0].init?.body));
  assert.equal(params.get("client_id"), CLIENT_ID);
  assert.equal(params.get("client_secret"), CLIENT_SECRET);
});

test("missing credentials stay not configured and do not call Shopify", async () => {
  const h = harness();
  const store = createShopifyTokenStore(h.deps);
  const got = await store.get();
  assert.equal(got.token, null);
  assert.equal(got.error, null);
  assert.equal(got.source, "none");
  assert.equal(h.calls.length, 0);
});

test("one of the two credentials reports an incomplete setup", async () => {
  const h = harness({ env: { SHOPIFY_CLIENT_ID: CLIENT_ID } });
  const store = createShopifyTokenStore(h.deps);
  const got = await store.get();
  assert.equal(got.token, null);
  assert.match(got.error || "", /incomplete/i);
  assert.equal(h.calls.length, 0);
  assert.doesNotMatch(got.error || "", new RegExp(CLIENT_ID));
});

test("a rejected exchange returns a clear error with no secret or token", async () => {
  const echoed = `bad secret ${CLIENT_SECRET} and id ${CLIENT_ID} and shpat_shouldnotleak`;
  const h = harness({
    env: { SHOPIFY_CLIENT_ID: CLIENT_ID, SHOPIFY_CLIENT_SECRET: CLIENT_SECRET },
    fetchImpl: async () => jsonResponse(401, { error: "invalid_client", error_description: echoed }),
  });
  const logs = silenceConsole();
  try {
    const store = createShopifyTokenStore(h.deps);
    const got = await store.get();
    assert.equal(got.token, null);
    assert.match(got.error || "", /rejected the app client id or secret/i);
    assert.doesNotMatch(got.error || "", new RegExp(CLIENT_SECRET));
    assert.doesNotMatch(got.error || "", new RegExp(CLIENT_ID));
    assert.doesNotMatch(got.error || "", /shpat_/);
    assert.equal(JSON.stringify(logs.seen).includes(CLIENT_SECRET), false);
    assert.equal(JSON.stringify(logs.seen).includes(CLIENT_ID), false);
  } finally {
    logs.restore();
  }
});

test("shop_not_permitted explains the organization requirement without echoing the body", async () => {
  const message = clientCredentialFailure(
    400,
    JSON.stringify({ error: "shop_not_permitted", error_description: `nope ${CLIENT_SECRET}` }),
    [CLIENT_SECRET, CLIENT_ID],
    SHOP,
  );
  assert.match(message, /same Shopify organization/);
  assert.match(message, new RegExp(SHOP));
  assert.doesNotMatch(message, new RegExp(CLIENT_SECRET));
});

test("a still-valid cached token is kept when a refresh fails before expiry", async () => {
  let attempt = 0;
  const h = harness({
    env: { SHOPIFY_CLIENT_ID: CLIENT_ID, SHOPIFY_CLIENT_SECRET: CLIENT_SECRET },
    fetchImpl: async () => {
      attempt += 1;
      if (attempt === 1) return tokenResponse("shpat_stillgood", 120);
      return jsonResponse(500, { error: "temporarily_unavailable", error_description: CLIENT_SECRET });
    },
  });
  const store = createShopifyTokenStore(h.deps);
  assert.equal((await store.get()).token, "shpat_stillgood");
  h.advance(120 * 1000 - CLIENT_CREDENTIAL_SKEW_MS + 1);
  const again = await store.get();
  assert.equal(again.token, "shpat_stillgood");
  assert.equal(again.error, null);
  assert.equal(attempt, 2);
});

test("force refresh failure does not keep the rejected token or the secret", async () => {
  const h = harness({
    env: { SHOPIFY_CLIENT_ID: CLIENT_ID, SHOPIFY_CLIENT_SECRET: CLIENT_SECRET },
    fetchImpl: async () => jsonResponse(401, { error: "invalid_client", error_description: CLIENT_SECRET }),
  });
  const store = createShopifyTokenStore(h.deps);
  const got = await store.get({ forceRefresh: true });
  assert.equal(got.token, null);
  assert.doesNotMatch(got.error || "", new RegExp(CLIENT_SECRET));
});

test("scrubSecrets redacts configured secrets and Shopify token prefixes", () => {
  const text = `id ${CLIENT_ID} secret ${CLIENT_SECRET} tok shpat_abcdef token shpca_zzzz`;
  const out = scrubSecrets(text, [CLIENT_ID, CLIENT_SECRET]);
  assert.equal(out.includes(CLIENT_ID), false);
  assert.equal(out.includes(CLIENT_SECRET), false);
  assert.equal(out.includes("shpat_abcdef"), false);
  assert.equal(out.includes("shpca_zzzz"), false);
});
