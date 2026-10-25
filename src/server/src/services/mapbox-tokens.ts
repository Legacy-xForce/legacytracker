/**
 * Mints Mapbox temporary tokens (`tk.*`) for the phone app.
 *
 * The app must not ship a Mapbox token, so it asks the tracker for one at
 * runtime. Minting needs a secret token with `tokens:write`; that secret stays
 * on the server. Temporary tokens cannot be revoked, so they are short-lived
 * and cached per user: a user's map screens share one token until shortly
 * before it expires, which keeps us well under the Tokens API limit of 100
 * requests per minute per account.
 */

const TOKENS_URL = "https://api.mapbox.com/tokens/v2";
/** Mapbox rejects an expiry more than an hour away. */
const MAX_TTL_SECONDS = 60 * 60;
const MIN_TTL_SECONDS = 60;
const DEFAULT_TTL_SECONDS = 55 * 60;
const DEFAULT_REFRESH_MARGIN_SECONDS = 5 * 60;
const TOKEN_SCOPES = ["styles:read", "fonts:read"] as const;

export interface MapboxTokenServiceOptions {
  /** Mapbox secret token with `tokens:write`, `styles:read` and `fonts:read`. */
  secretToken?: string | null;
  /** Mapbox account username that owns the tokens. */
  username?: string | null;
  /** Requested lifetime, in seconds. Capped at one hour by Mapbox. */
  ttlSeconds?: number;
  /** Renew this long before expiry, so the app never holds a dead token. */
  refreshMarginSeconds?: number;
  /** Injected for tests; defaults to the global `fetch`. */
  fetch?: typeof fetch;
  /** Injected for tests; milliseconds since the epoch. */
  now?: () => number;
}

export interface IssuedMapboxToken {
  token: string;
  /** ISO 8601, as returned to the app. */
  expiresAt: string;
}

interface CachedToken {
  token: string;
  /** Epoch milliseconds; when this passes the token is replaced. */
  refreshAt: number;
  expiresAt: number;
}

/** The server has no Mapbox credentials, so it cannot mint tokens. */
export class MapboxNotConfiguredError extends Error {
  constructor() {
    super("MAPBOX_SECRET_TOKEN and MAPBOX_USERNAME are not configured");
    this.name = "MapboxNotConfiguredError";
  }
}

/** Mapbox refused the request. The message never contains the secret. */
export class MapboxTokenRequestError extends Error {
  constructor(
    message: string,
    readonly status: number | null = null,
  ) {
    super(message);
    this.name = "MapboxTokenRequestError";
  }
}

function bounded(value: number | undefined, fallback: number, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(value)));
}

export class MapboxTokenService {
  private readonly secretToken: string;
  private readonly username: string;
  private readonly ttlSeconds: number;
  private readonly refreshMarginSeconds: number;
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;
  private readonly cache = new Map<string, CachedToken>();
  private readonly pending = new Map<string, Promise<CachedToken>>();

  constructor(options: MapboxTokenServiceOptions = {}) {
    this.secretToken = options.secretToken?.trim() ?? "";
    this.username = options.username?.trim() ?? "";
    this.ttlSeconds = bounded(
      options.ttlSeconds,
      DEFAULT_TTL_SECONDS,
      MIN_TTL_SECONDS,
      MAX_TTL_SECONDS,
    );
    this.refreshMarginSeconds = bounded(
      options.refreshMarginSeconds,
      DEFAULT_REFRESH_MARGIN_SECONDS,
      0,
      this.ttlSeconds,
    );
    this.fetchImpl = options.fetch ?? fetch;
    this.now = options.now ?? Date.now;
  }

  get configured(): boolean {
    return this.secretToken.length > 0 && this.username.length > 0;
  }

  /**
   * Returns a cached temporary token for this user, minting one if needed.
   * Concurrent callers share a single Tokens API request.
   */
  async getForUser(userId: string): Promise<IssuedMapboxToken> {
    if (!this.configured) {
      throw new MapboxNotConfiguredError();
    }
    const cached = this.cache.get(userId);
    if (cached && cached.refreshAt > this.now()) {
      return { token: cached.token, expiresAt: new Date(cached.expiresAt).toISOString() };
    }

    let request = this.pending.get(userId);
    if (!request) {
      request = this.mint().finally(() => {
        this.pending.delete(userId);
      });
      this.pending.set(userId, request);
    }
    const minted = await request;
    this.cache.set(userId, minted);
    return { token: minted.token, expiresAt: new Date(minted.expiresAt).toISOString() };
  }

  private async mint(): Promise<CachedToken> {
    const issuedAt = this.now();
    const expiresAt = issuedAt + this.ttlSeconds * 1000;
    const url = `${TOKENS_URL}/${encodeURIComponent(this.username)}?access_token=${encodeURIComponent(this.secretToken)}`;

    let response: Response;
    try {
      response = await this.fetchImpl(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          expires: new Date(expiresAt).toISOString(),
          scopes: TOKEN_SCOPES,
        }),
      });
    } catch {
      // A network error can include the URL, which carries the secret. Replace
      // it with a message that is safe to log.
      throw new MapboxTokenRequestError("Mapbox token request failed");
    }

    if (!response.ok) {
      throw new MapboxTokenRequestError(
        `Mapbox token request failed with status ${response.status}`,
        response.status,
      );
    }

    const body = (await response.json().catch(() => null)) as
      | { token?: unknown; expires?: unknown }
      | null;
    if (!body || typeof body.token !== "string" || body.token.length === 0) {
      throw new MapboxTokenRequestError("Mapbox token response did not contain a token");
    }

    const reportedExpiry =
      typeof body.expires === "string" ? Date.parse(body.expires) : Number.NaN;
    const actualExpiry = Number.isFinite(reportedExpiry) ? reportedExpiry : expiresAt;
    const refreshAt = Math.max(
      issuedAt + 1000,
      actualExpiry - this.refreshMarginSeconds * 1000,
    );
    return { token: body.token, refreshAt, expiresAt: actualExpiry };
  }
}
