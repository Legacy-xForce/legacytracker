import crypto from "crypto";
import type { Pool } from "pg";

export const API_TOKEN_PREFIX = "legacy-tracker-";
export const API_TOKEN_SCOPES = ["read", "write"] as const;
export type ApiTokenScope = (typeof API_TOKEN_SCOPES)[number];

export const MAX_API_TOKENS_PER_USER = 25;
export const MAX_API_TOKEN_NAME_LENGTH = 60;
const DEFAULT_TOKEN_NAME = "API token";

// Integrations may poll or upload every few seconds; caching keeps each call
// from costing a lookup. Rotation and deletion drop the cached entry, so a
// replaced token stops working at once.
const CACHE_TTL_MS = 60_000;
const NEGATIVE_CACHE_TTL_MS = 30_000;
const TOUCH_INTERVAL_MS = 60_000;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface ApiTokenIdentity {
  tokenId: string;
  userId: string;
  userName: string;
  scope: ApiTokenScope;
}

/** What lists show: everything except the secret. */
export interface ApiTokenSummary {
  id: string;
  name: string;
  scope: ApiTokenScope;
  token_hint: string;
  created_at: string;
  last_used_at: string | null;
  rotated_at: string | null;
}

/** Returned once, at creation or rotation: the only time the token is visible. */
export interface IssuedApiToken extends ApiTokenSummary {
  token: string;
}

export type ApiTokenInput =
  | { ok: true; value: { name: string; scope: ApiTokenScope } }
  | { ok: false; error: string };

interface ApiTokenRow {
  id: string;
  name: string;
  scope: ApiTokenScope;
  token_hint: string;
  created_at: Date;
  last_used_at: Date | null;
  rotated_at: Date | null;
}

interface CacheEntry {
  identity: ApiTokenIdentity | null;
  expiresAt: number;
}

const SUMMARY_COLUMNS =
  "id, name, scope, token_hint, created_at, last_used_at, rotated_at";

export function generateApiToken(): string {
  return `${API_TOKEN_PREFIX}${crypto.randomUUID()}`;
}

export function hashApiToken(token: string): string {
  return crypto.createHash("sha256").update(token, "utf8").digest("hex");
}

/** A non-secret label that tells tokens apart in a list. */
export function apiTokenHint(token: string): string {
  const body = token.slice(API_TOKEN_PREFIX.length);
  return `${API_TOKEN_PREFIX}${body.slice(0, 4)}…${body.slice(-4)}`;
}

/** Filters obvious junk before it costs a hash and a lookup. */
export function isApiTokenShape(token: string): boolean {
  if (!token.startsWith(API_TOKEN_PREFIX)) {
    return false;
  }
  const body = token.slice(API_TOKEN_PREFIX.length);
  return body.length >= 8 && body.length <= 128 && /^[A-Za-z0-9-]+$/.test(body);
}

export function isApiTokenId(id: string): boolean {
  return UUID_PATTERN.test(id);
}

export function validateApiTokenInput(body: unknown): ApiTokenInput {
  const input = (body ?? {}) as Record<string, unknown>;
  const scope = input.scope;
  if (scope !== "read" && scope !== "write") {
    return { ok: false, error: "`scope` must be \"read\" or \"write\"" };
  }
  if (input.name !== undefined && typeof input.name !== "string") {
    return { ok: false, error: "`name` must be a string" };
  }
  const name = (input.name ?? "").trim() || DEFAULT_TOKEN_NAME;
  if (name.length > MAX_API_TOKEN_NAME_LENGTH) {
    return {
      ok: false,
      error: `\`name\` must be at most ${MAX_API_TOKEN_NAME_LENGTH} characters`,
    };
  }
  return { ok: true, value: { name, scope } };
}

/**
 * Whether a token with `scope` may make this request. `read` covers every
 * GET plus the stream ticket, which is a POST only because it hands out a
 * single-use credential; it changes nothing. `write` may do anything the
 * user's session can, apart from the session-only routes the caller excludes.
 */
export function isAllowedForScope(
  scope: ApiTokenScope,
  method: string,
  route: string,
): boolean {
  if (scope === "write") {
    return true;
  }
  const verb = method.toUpperCase();
  if (verb === "GET" || verb === "HEAD" || verb === "OPTIONS") {
    return true;
  }
  return verb === "POST" && route === "/api/v1/streams/ticket";
}

function toSummary(row: ApiTokenRow): ApiTokenSummary {
  return {
    id: row.id,
    name: row.name,
    scope: row.scope,
    token_hint: row.token_hint,
    created_at: row.created_at.toISOString(),
    last_used_at: row.last_used_at?.toISOString() ?? null,
    rotated_at: row.rotated_at?.toISOString() ?? null,
  };
}

export class ApiTokenLimitError extends Error {}

/**
 * Personal, non-expiring credentials for integrations, sent as
 * `X-API-Token: legacy-tracker-<uuid>`. They act as the user who created
 * them, limited by scope. Only sha256(token) is stored, so a token is shown
 * once and lost tokens are rotated, not recovered.
 */
export class ApiTokens {
  private readonly cache = new Map<string, CacheEntry>();
  private readonly lastTouch = new Map<string, number>();

  constructor(private readonly pool: Pool) {}

  async list(userId: string): Promise<ApiTokenSummary[]> {
    const { rows } = await this.pool.query<ApiTokenRow>(
      `SELECT ${SUMMARY_COLUMNS} FROM api_tokens
       WHERE user_id = $1 ORDER BY created_at DESC`,
      [userId],
    );
    return rows.map(toSummary);
  }

  async create(
    userId: string,
    name: string,
    scope: ApiTokenScope,
  ): Promise<IssuedApiToken> {
    const token = generateApiToken();
    // The count and insert share one statement so two concurrent creates
    // can't both slip under the limit.
    const { rows } = await this.pool.query<ApiTokenRow>(
      `INSERT INTO api_tokens (user_id, name, scope, token_hash, token_hint)
       SELECT $1, $2, $3, $4, $5
       WHERE (SELECT count(*) FROM api_tokens WHERE user_id = $1) < $6
       RETURNING ${SUMMARY_COLUMNS}`,
      [
        userId,
        name,
        scope,
        hashApiToken(token),
        apiTokenHint(token),
        MAX_API_TOKENS_PER_USER,
      ],
    );
    if (rows.length === 0) {
      throw new ApiTokenLimitError(
        `You already have ${MAX_API_TOKENS_PER_USER} API tokens. Delete one first.`,
      );
    }
    return { ...toSummary(rows[0]), token };
  }

  /** Replaces the secret; the old value stops working immediately. */
  async rotate(userId: string, id: string): Promise<IssuedApiToken | null> {
    const token = generateApiToken();
    const { rows } = await this.pool.query<ApiTokenRow & { old_hash: string }>(
      `WITH old AS (
         SELECT id, token_hash FROM api_tokens
         WHERE id = $1 AND user_id = $2 FOR UPDATE
       )
       UPDATE api_tokens t
       SET token_hash = $3, token_hint = $4, rotated_at = now(), last_used_at = NULL
       FROM old WHERE t.id = old.id
       RETURNING t.id, t.name, t.scope, t.token_hint, t.created_at,
                 t.last_used_at, t.rotated_at, old.token_hash AS old_hash`,
      [id, userId, hashApiToken(token), apiTokenHint(token)],
    );
    const row = rows[0];
    if (!row) {
      return null;
    }
    this.forget(row.old_hash, row.id);
    return { ...toSummary(row), token };
  }

  async remove(userId: string, id: string): Promise<boolean> {
    const { rows } = await this.pool.query<{ id: string; token_hash: string }>(
      `DELETE FROM api_tokens WHERE id = $1 AND user_id = $2
       RETURNING id, token_hash`,
      [id, userId],
    );
    for (const row of rows) {
      this.forget(row.token_hash, row.id);
    }
    return rows.length > 0;
  }

  /**
   * Drops every token of a user who has lost access to the tracker. Tokens
   * carry no Legacy Auth claims of their own, so this is how a revoked scope
   * reaches them.
   */
  async removeAllForUser(userId: string): Promise<number> {
    const { rows } = await this.pool.query<{ id: string; token_hash: string }>(
      "DELETE FROM api_tokens WHERE user_id = $1 RETURNING id, token_hash",
      [userId],
    );
    for (const row of rows) {
      this.forget(row.token_hash, row.id);
    }
    return rows.length;
  }

  async authenticate(rawToken: string): Promise<ApiTokenIdentity | null> {
    const token = rawToken.trim();
    if (!isApiTokenShape(token)) {
      return null;
    }
    const hash = hashApiToken(token);
    const now = Date.now();
    const cached = this.cache.get(hash);
    if (cached && cached.expiresAt > now) {
      if (cached.identity) void this.touch(cached.identity.tokenId);
      return cached.identity;
    }

    const { rows } = await this.pool.query<{
      id: string;
      user_id: string;
      scope: ApiTokenScope;
      name: string;
    }>(
      `SELECT t.id, t.user_id, t.scope, u.name
       FROM api_tokens t
       JOIN users u ON u.id = t.user_id
       WHERE t.token_hash = $1`,
      [hash],
    );
    const row = rows[0];
    const identity = row
      ? {
          tokenId: row.id,
          userId: row.user_id,
          userName: row.name,
          scope: row.scope,
        }
      : null;
    this.cache.set(hash, {
      identity,
      expiresAt: now + (identity ? CACHE_TTL_MS : NEGATIVE_CACHE_TTL_MS),
    });
    if (identity) void this.touch(identity.tokenId);
    return identity;
  }

  /** Records when a token was last used, throttled to one write a minute. */
  private async touch(tokenId: string): Promise<void> {
    const now = Date.now();
    if (now - (this.lastTouch.get(tokenId) ?? 0) < TOUCH_INTERVAL_MS) {
      return;
    }
    this.lastTouch.set(tokenId, now);
    try {
      await this.pool.query(
        "UPDATE api_tokens SET last_used_at = now() WHERE id = $1",
        [tokenId],
      );
    } catch {
      // Usage tracking must never fail an otherwise valid request.
    }
  }

  private forget(hash: string, tokenId: string): void {
    this.cache.delete(hash);
    this.lastTouch.delete(tokenId);
  }
}
