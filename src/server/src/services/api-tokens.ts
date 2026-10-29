import crypto from "crypto";
import net from "net";
import type { Pool } from "pg";

export const API_TOKEN_PREFIX = "legacy-tracker-";
export const API_TOKEN_SCOPES = ["read", "write"] as const;
export type ApiTokenScope = (typeof API_TOKEN_SCOPES)[number];

export const MAX_API_TOKENS_PER_USER = 25;
export const MAX_API_TOKEN_NAME_LENGTH = 60;
export const MAX_ALLOWED_IPS_PER_TOKEN = 32;
const DEFAULT_TOKEN_NAME = "API token";

// Integrations may poll or upload every few seconds; caching keeps each call
// from costing a lookup. Rotation, deletion and allowlist edits drop the
// cached entry, so a change applies to the next request at once.
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
  /** Addresses the token may be used from; empty means no restriction. */
  allowedIps: string[];
}

/** What lists show: everything except the secret. */
export interface ApiTokenSummary {
  id: string;
  name: string;
  scope: ApiTokenScope;
  token_hint: string;
  allowed_ips: string[];
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

export type AllowedIpsInput =
  | { ok: true; value: string[] }
  | { ok: false; error: string };

interface ApiTokenRow {
  id: string;
  name: string;
  scope: ApiTokenScope;
  token_hint: string;
  allowed_ips: string[];
  created_at: Date;
  last_used_at: Date | null;
  rotated_at: Date | null;
}

interface CacheEntry {
  identity: ApiTokenIdentity | null;
  expiresAt: number;
}

interface AllowedIp {
  bytes: number[];
  prefix: number;
  text: string;
}

const SUMMARY_COLUMNS =
  "id, name, scope, token_hint, allowed_ips, created_at, last_used_at, rotated_at";

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

function ipv4Bytes(value: string): number[] | null {
  return net.isIP(value) === 4 ? value.split(".").map(Number) : null;
}

/** The eight 16-bit words of an IPv6 address, `::` expanded. */
function ipv6Words(value: string): number[] | null {
  let text = value;
  const tail = text.slice(text.lastIndexOf(":") + 1);
  if (tail.includes(".")) {
    // `::ffff:1.2.3.4` ends in a dotted quad standing for two words.
    const four = ipv4Bytes(tail);
    if (!four) {
      return null;
    }
    const high = ((four[0] << 8) | four[1]).toString(16);
    const low = ((four[2] << 8) | four[3]).toString(16);
    text = `${text.slice(0, text.lastIndexOf(":") + 1)}${high}:${low}`;
  }
  const halves = text.split("::");
  if (halves.length > 2) {
    return null;
  }
  const words = (chunk: string): number[] =>
    chunk.length === 0
      ? []
      : chunk.split(":").map((word) => parseInt(word, 16));
  if (halves.length === 2) {
    const left = words(halves[0]);
    const right = words(halves[1]);
    const zeros = 8 - left.length - right.length;
    if (zeros < 0) {
      return null;
    }
    return [...left, ...new Array<number>(zeros).fill(0), ...right];
  }
  const full = words(text);
  return full.length === 8 ? full : null;
}

/**
 * Address as 4 or 16 bytes, with IPv4-mapped IPv6 (`::ffff:1.2.3.4`, what a
 * dual-stack socket reports for an IPv4 peer) collapsed to its 4-byte form so
 * the same host compares equal however it was written.
 */
function addressBytes(value: string): number[] | null {
  const four = ipv4Bytes(value);
  if (four) {
    return four;
  }
  if (net.isIP(value) !== 6) {
    return null;
  }
  const words = ipv6Words(value);
  if (!words) {
    return null;
  }
  const bytes: number[] = [];
  for (const word of words) {
    bytes.push((word >> 8) & 0xff, word & 0xff);
  }
  if (
    bytes.length === 16 &&
    bytes.every((byte, index) =>
      index < 10 ? byte === 0 : index < 12 ? byte === 0xff : true,
    )
  ) {
    return bytes.slice(12);
  }
  return bytes;
}

/**
 * An allowlist entry: a bare address (one host) or `<address>/<prefix>`.
 * `text` is how the entry is stored and shown; null for anything that is not
 * an address, including IPv6 zone ids, which cannot be matched.
 */
function parseCidr(entry: string): AllowedIp | null {
  const parts = entry.trim().toLowerCase().split("/");
  if (parts.length > 2) {
    return null;
  }
  const [address, prefixText] = parts;
  if (address.includes("%")) {
    return null;
  }
  const bytes = addressBytes(address);
  if (!bytes) {
    return null;
  }
  const bits = bytes.length * 8;
  if (prefixText !== undefined && !/^\d+$/.test(prefixText)) {
    return null;
  }
  const prefix = prefixText === undefined ? bits : Number(prefixText);
  if (prefix > bits) {
    return null;
  }
  // Written from the resolved bytes where they differ from the input, so
  // `::ffff:1.2.3.4` is stored as `1.2.3.4` and deduplicates against it.
  const canonical = bytes.length === 4 ? bytes.join(".") : address;
  return {
    bytes,
    prefix,
    // A full-length prefix says nothing the bare address does not: keep the
    // shorter form so `1.2.3.4` and `1.2.3.4/32` deduplicate.
    text: prefix === bits ? canonical : `${canonical}/${prefix}`,
  };
}

function sharesLeadingBits(a: number[], b: number[], prefix: number): boolean {
  for (let bit = 0; bit < prefix; bit += 8) {
    const taken = Math.min(8, prefix - bit);
    const mask = (0xff << (8 - taken)) & 0xff;
    if ((a[bit / 8] & mask) !== (b[bit / 8] & mask)) {
      return false;
    }
  }
  return true;
}

/** Canonical text for a single address, or null if it is not one. */
export function normalizeIp(value: string): string | null {
  const text = value.trim().toLowerCase();
  if (text.includes("/")) {
    return null;
  }
  const entry = parseCidr(text);
  return entry ? entry.text : null;
}

/** Validates a submitted allowlist: deduplicated, canonically written, small. */
export function parseAllowedIps(value: unknown): AllowedIpsInput {
  if (!Array.isArray(value)) {
    return {
      ok: false,
      error: "`allowed_ips` must be a list of addresses or CIDR prefixes",
    };
  }
  const entries: string[] = [];
  for (const item of value) {
    const entry =
      typeof item === "string" ? parseCidr(item) : null;
    if (!entry) {
      return {
        ok: false,
        error: `\`${String(item)}\` is not an IP address or CIDR prefix`,
      };
    }
    if (!entries.includes(entry.text)) {
      entries.push(entry.text);
    }
  }
  if (entries.length > MAX_ALLOWED_IPS_PER_TOKEN) {
    return {
      ok: false,
      error: `\`allowed_ips\` holds at most ${MAX_ALLOWED_IPS_PER_TOKEN} entries`,
    };
  }
  return { ok: true, value: entries };
}

/**
 * Whether `clientIp` may use a token restricted to `allowed`. An empty list is
 * no restriction: tokens predating the feature keep working from anywhere.
 * Families never match across, so an IPv4 entry excludes IPv6 callers — the
 * `::ffff:` form is the exception, since it *is* an IPv4 address.
 */
export function ipMatchesAllowlist(
  clientIp: string,
  allowed: readonly string[],
): boolean {
  if (allowed.length === 0) {
    return true;
  }
  const target = addressBytes(clientIp.trim().toLowerCase());
  if (!target) {
    return false;
  }
  for (const entry of allowed) {
    const parsed = parseCidr(entry);
    if (!parsed || parsed.bytes.length !== target.length) {
      continue;
    }
    if (sharesLeadingBits(target, parsed.bytes, parsed.prefix)) {
      return true;
    }
  }
  return false;
}

function toSummary(row: ApiTokenRow): ApiTokenSummary {
  return {
    id: row.id,
    name: row.name,
    scope: row.scope,
    token_hint: row.token_hint,
    allowed_ips: row.allowed_ips,
    created_at: row.created_at.toISOString(),
    last_used_at: row.last_used_at?.toISOString() ?? null,
    rotated_at: row.rotated_at?.toISOString() ?? null,
  };
}

export class ApiTokenLimitError extends Error {}

/**
 * Personal, non-expiring credentials for integrations, sent as
 * `X-API-Token: legacy-tracker-<uuid>`. They act as their owner, limited by
 * scope and, optionally, by the source address they were last used from.
 * Only sha256(token) is stored, so a token is shown once and lost tokens are
 * rotated, not recovered.
 */
export class ApiTokens {
  private readonly cache = new Map<string, CacheEntry>();
  private readonly lastTouch = new Map<string, number>();

  constructor(private readonly pool: Pool) {}

  async list(userId: string): Promise<ApiTokenSummary[]> {
    const { rows } = await this.pool.query<ApiTokenRow>(
      `SELECT ${SUMMARY_COLUMNS} FROM api_tokens
       WHERE user_id = $1 AND NOT deleted ORDER BY created_at DESC`,
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
       WHERE (SELECT count(*) FROM api_tokens
              WHERE user_id = $1 AND NOT deleted) < $6
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
         WHERE id = $1 AND user_id = $2 AND NOT deleted FOR UPDATE
       )
       UPDATE api_tokens t
       SET token_hash = $3, token_hint = $4, rotated_at = now(), last_used_at = NULL
       FROM old WHERE t.id = old.id
       RETURNING t.id, t.name, t.scope, t.token_hint, t.allowed_ips,
                 t.created_at, t.last_used_at, t.rotated_at,
                 old.token_hash AS old_hash`,
      [id, userId, hashApiToken(token), apiTokenHint(token)],
    );
    const row = rows[0];
    if (!row) {
      return null;
    }
    this.forget(row.old_hash, row.id);
    return { ...toSummary(row), token };
  }

  /**
   * Restricts a token to the given source addresses; an empty list removes the
   * restriction. The cached identity holds the list, so it goes with the old
   * value — the cache key is a hash of a secret this method never sees.
   */
  async updateAllowedIps(
    userId: string,
    id: string,
    allowedIps: string[],
  ): Promise<ApiTokenSummary | null> {
    const { rows } = await this.pool.query<ApiTokenRow>(
      `UPDATE api_tokens SET allowed_ips = $3
       WHERE id = $1 AND user_id = $2 AND NOT deleted
       RETURNING ${SUMMARY_COLUMNS}`,
      [id, userId, allowedIps],
    );
    const row = rows[0];
    if (!row) {
      return null;
    }
    this.forgetIdentity(row.id);
    return toSummary(row);
  }

  /**
   * Marks a token deleted instead of removing the row, so its request trail
   * keeps a token to point at. `authenticate` ignores deleted rows, so this
   * takes effect on the next request just like a hard delete.
   */
  async remove(userId: string, id: string): Promise<boolean> {
    const { rows } = await this.pool.query<{ id: string; token_hash: string }>(
      `UPDATE api_tokens SET deleted = true
       WHERE id = $1 AND user_id = $2 AND NOT deleted
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
      `UPDATE api_tokens SET deleted = true
       WHERE user_id = $1 AND NOT deleted
       RETURNING id, token_hash`,
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
      allowed_ips: string[];
    }>(
      `SELECT t.id, t.user_id, t.scope, t.allowed_ips, u.name
       FROM api_tokens t
       JOIN users u ON u.id = t.user_id
       WHERE t.token_hash = $1 AND NOT t.deleted`,
      [hash],
    );
    const row = rows[0];
    const identity = row
      ? {
          tokenId: row.id,
          userId: row.user_id,
          userName: row.name,
          scope: row.scope,
          allowedIps: row.allowed_ips,
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

  /** Drops the cached identity of a token, whichever secret produced it. */
  private forgetIdentity(tokenId: string): void {
    for (const [hash, entry] of this.cache) {
      if (entry.identity?.tokenId === tokenId) {
        this.cache.delete(hash);
      }
    }
    this.lastTouch.delete(tokenId);
  }
}
