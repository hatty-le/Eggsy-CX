// Shopify Admin token for cx-actions.
// Static token first (edge secret, then Vault). Otherwise the Dev Dashboard
// client-credentials grant. Never log client secrets or access tokens.
// https://shopify.dev/docs/apps/build/authentication-authorization/client-credentials-grant

export const CLIENT_CREDENTIAL_SKEW_MS = 60_000;
const DEFAULT_EXPIRES_IN_SECONDS = 86399;

export type ShopifyTokenSource = "static" | "client_credentials" | "none";

export type ShopifyTokenResult = {
  token: string | null;
  source: ShopifyTokenSource;
  error: string | null;
};

export type VaultClientCredentials = {
  clientId: string | null;
  clientSecret: string | null;
  error: string | null;
};

export type ShopifyTokenDeps = {
  shop: string;
  readEnv: (name: string) => string | undefined;
  readVaultAdminToken: () => Promise<string | null>;
  readVaultClientCredentials: () => Promise<VaultClientCredentials>;
  fetchImpl?: typeof fetch;
  now?: () => number;
};

function clean(value: string | null | undefined): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function shopHost(shop: string): string {
  return shop.trim().replace(/^https?:\/\//i, "").replace(/\/+$/, "");
}

export function scrubSecrets(text: string, secrets: Array<string | null | undefined>): string {
  let out = text;
  const seen = new Set<string>();
  for (const secret of secrets) {
    const value = clean(secret);
    if (!value || value.length < 8 || seen.has(value)) continue;
    seen.add(value);
    out = out.split(value).join("[redacted]");
  }
  return out
    .replace(/shpat_[A-Za-z0-9]+/g, "[redacted]")
    .replace(/shp(?:ca|at|ss|ua)_[A-Za-z0-9]+/g, "[redacted]");
}

function expiresInSeconds(value: unknown): number {
  const n = typeof value === "number"
    ? value
    : typeof value === "string" && value.trim() !== ""
      ? Number(value)
      : NaN;
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_EXPIRES_IN_SECONDS;
  return n;
}

function oauthErrorFields(raw: string): { code: string; description: string } {
  const trimmed = raw.trim();
  if (!trimmed) return { code: "", description: "" };
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    try {
      const body = JSON.parse(trimmed) as Record<string, unknown>;
      const code = typeof body.error === "string"
        ? body.error
        : typeof body.errors === "string"
          ? body.errors
          : "";
      const description = typeof body.error_description === "string" ? body.error_description : "";
      return { code, description };
    } catch {
      return { code: "", description: "" };
    }
  }
  if (!trimmed.includes("error=")) return { code: "", description: "" };
  const params = new URLSearchParams(trimmed);
  return {
    code: params.get("error") || "",
    description: params.get("error_description") || "",
  };
}

export function clientCredentialFailure(status: number, raw: string, secrets: Array<string | null | undefined>, shop: string): string {
  const fields = oauthErrorFields(raw);
  const code = scrubSecrets(fields.code, secrets).slice(0, 180);
  const description = scrubSecrets(fields.description, secrets).slice(0, 240);
  const blob = `${code} ${description}`;
  const host = shopHost(shop) || "the store";
  if (/shop_not_permitted/i.test(blob)) {
    return `Shopify refused the client credentials grant for ${host}. The Dev Dashboard app must be installed on this store and belong to the same Shopify organization.`;
  }
  if (status === 401 || /invalid_client/i.test(code)) {
    return "Shopify rejected the app client id or secret. Check the SHOPIFY_CLIENT_ID and SHOPIFY_CLIENT_SECRET edge secrets, or the Vault secrets shopify_client_id and shopify_client_secret.";
  }
  if (status === 404) {
    return `Shopify token request failed (HTTP 404). Check SHOPIFY_STORE_DOMAIN. The host must be the myshopify.com store the Dev Dashboard app is installed on (got ${host}).`;
  }
  if (status === 429) {
    return "Shopify token request was rate limited (HTTP 429). Try again shortly.";
  }
  const detail = [code, description].filter(Boolean).join(": ");
  return detail
    ? `Shopify token request failed (HTTP ${status}): ${detail}`
    : `Shopify token request failed (HTTP ${status}).`;
}

const INCOMPLETE = "Shopify client credentials are incomplete. Set both SHOPIFY_CLIENT_ID and SHOPIFY_CLIENT_SECRET (edge secrets), or both Vault secrets shopify_client_id and shopify_client_secret.";

export function createShopifyTokenStore(deps: ShopifyTokenDeps) {
  const fetchImpl = deps.fetchImpl || fetch;
  const now = deps.now || (() => Date.now());
  let cache: { token: string; expiresAt: number } | null = null;
  let pending: Promise<ShopifyTokenResult> | null = null;

  function cachedResult(): ShopifyTokenResult | null {
    if (!cache) return null;
    if (now() < cache.expiresAt - CLIENT_CREDENTIAL_SKEW_MS) {
      return { token: cache.token, source: "client_credentials", error: null };
    }
    return null;
  }

  async function staticToken(): Promise<string | null> {
    const fromEnv = clean(deps.readEnv("SHOPIFY_ADMIN_ACCESS_TOKEN"));
    if (fromEnv) return fromEnv;
    return clean(await deps.readVaultAdminToken());
  }

  async function clientPair(): Promise<{ id: string; secret: string } | ShopifyTokenResult> {
    let id = clean(deps.readEnv("SHOPIFY_CLIENT_ID"));
    let secret = clean(deps.readEnv("SHOPIFY_CLIENT_SECRET"));
    if (id && secret) return { id, secret };
    const vault = await deps.readVaultClientCredentials();
    if (vault.error && !(id && secret)) {
      id = id || clean(vault.clientId);
      secret = secret || clean(vault.clientSecret);
      if (!(id && secret)) {
        return { token: null, source: "none", error: vault.error };
      }
    } else {
      id = id || clean(vault.clientId);
      secret = secret || clean(vault.clientSecret);
    }
    if (id && secret) return { id, secret };
    if (id || secret) return { token: null, source: "none", error: INCOMPLETE };
    return { token: null, source: "none", error: null };
  }

  async function exchange(force: boolean): Promise<ShopifyTokenResult> {
    const host = shopHost(deps.shop);
    if (!host) {
      return { token: null, source: "none", error: "Shopify store domain is not set." };
    }
    const creds = await clientPair();
    if ("token" in creds) {
      cache = null;
      return creds;
    }
    const previous = cache;
    let res: Response;
    try {
      res = await fetchImpl(`https://${host}/admin/oauth/access_token`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "client_credentials",
          client_id: creds.id,
          client_secret: creds.secret,
        }),
      });
    } catch {
      if (!force && previous && now() < previous.expiresAt) {
        return { token: previous.token, source: "client_credentials", error: null };
      }
      cache = null;
      return { token: null, source: "none", error: "Could not reach Shopify to exchange the app client credentials." };
    }
    const raw = await res.text();
    if (!res.ok) {
      const error = clientCredentialFailure(res.status, raw, [creds.id, creds.secret, previous?.token], host);
      if (!force && previous && now() < previous.expiresAt) {
        return { token: previous.token, source: "client_credentials", error: null };
      }
      cache = null;
      return { token: null, source: "none", error };
    }
    let body: Record<string, unknown> = {};
    try {
      body = raw ? JSON.parse(raw) as Record<string, unknown> : {};
    } catch {
      cache = null;
      return { token: null, source: "none", error: "Shopify token response was not valid JSON." };
    }
    const token = typeof body.access_token === "string" ? body.access_token.trim() : "";
    if (!token) {
      cache = null;
      return { token: null, source: "none", error: "Shopify accepted the client credentials but did not return an access token." };
    }
    const lifetimeMs = expiresInSeconds(body.expires_in) * 1000;
    cache = { token, expiresAt: now() + lifetimeMs };
    return { token, source: "client_credentials", error: null };
  }

  async function load(force: boolean): Promise<ShopifyTokenResult> {
    const stat = await staticToken();
    if (stat) return { token: stat, source: "static", error: null };
    if (!force) {
      const hit = cachedResult();
      if (hit) return hit;
    }
    return exchange(force);
  }

  return {
    async get(opts?: { forceRefresh?: boolean }): Promise<ShopifyTokenResult> {
      const force = !!opts?.forceRefresh;
      if (!force && pending) return pending;
      if (force) return load(true);
      let run: Promise<ShopifyTokenResult>;
      run = load(false).finally(() => {
        if (pending === run) pending = null;
      });
      pending = run;
      return run;
    },
    invalidate() {
      cache = null;
    },
  };
}
