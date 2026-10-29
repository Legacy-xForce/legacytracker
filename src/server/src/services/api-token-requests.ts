import type { Pool } from "pg";

/** Trailers are informational, so keep a bound on what the table stores. */
export const MAX_USER_AGENT_LENGTH = 512;

export const DEFAULT_API_TOKEN_REQUEST_LIMIT = 50;
export const MAX_API_TOKEN_REQUEST_LIMIT = 200;

export interface ApiTokenRequestEntry {
  tokenId: string;
  userId: string;
  method: string;
  /** Path only: query strings never contain a token, but they can hold data. */
  path: string;
  statusCode: number;
  clientIp: string;
  userAgent: string | null;
  durationMs: number;
}

/** One row as the token's own activity view shows it. */
export interface ApiTokenRequestSummary {
  id: string;
  method: string;
  path: string;
  status_code: number;
  client_ip: string | null;
  user_agent: string | null;
  duration_ms: number | null;
  created_at: string;
}

export interface ApiTokenRequestPage {
  requests: ApiTokenRequestSummary[];
  has_more: boolean;
  /** Pass back as `before` to fetch the next page; null on the last one. */
  next_before: string | null;
}

interface ApiTokenRequestRow {
  id: string;
  method: string;
  path: string;
  status_code: number;
  client_ip: string | null;
  user_agent: string | null;
  duration_ms: number | null;
  created_at: Date;
}

function toSummary(row: ApiTokenRequestRow): ApiTokenRequestSummary {
  return {
    id: row.id,
    method: row.method,
    path: row.path,
    status_code: row.status_code,
    client_ip: row.client_ip,
    user_agent: row.user_agent,
    duration_ms: row.duration_ms,
    created_at: row.created_at.toISOString(),
  };
}

/** Names the request without leaking the query string into the audit trail. */
export function requestPath(url: string): string {
  const query = url.indexOf("?");
  return query === -1 ? url : url.slice(0, query);
}

/** Normalizes the `User-Agent` header and bounds it for storage. */
export function userAgentOf(
  value: string | string[] | undefined,
): string | null {
  const header = Array.isArray(value) ? value[0] : value;
  if (!header) {
    return null;
  }
  return header.length > MAX_USER_AGENT_LENGTH
    ? header.slice(0, MAX_USER_AGENT_LENGTH)
    : header;
}

/**
 * Persistent trail of requests made with personal API tokens, so anyone
 * signed in can audit what integrations do and security can investigate a
 * leaked token. Rows include requests the token's scope or address allowlist
 * turned away. A deleted token's history stays in the database, though the
 * API no longer exposes it.
 */
export class ApiTokenRequests {
  constructor(private readonly pool: Pool) {}

  async record(entry: ApiTokenRequestEntry): Promise<void> {
    await this.pool.query(
      `INSERT INTO api_token_requests
         (token_id, user_id, method, path, status_code, client_ip,
          user_agent, duration_ms)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        entry.tokenId,
        entry.userId,
        entry.method,
        entry.path,
        entry.statusCode,
        entry.clientIp,
        entry.userAgent,
        entry.durationMs,
      ],
    );
  }

  /**
   * Newest first, one page at a time. Any signed-in user may read any live
   * token's trail, which is what makes it an audit log. Deleted tokens are
   * left to the database. Returns null when no live token has that id, which
   * the route turns into a 404.
   */
  async listForToken(
    tokenId: string,
    options: { limit: number; before: string | null },
  ): Promise<ApiTokenRequestPage | null> {
    const exists = await this.pool.query(
      "SELECT 1 FROM api_tokens WHERE id = $1 AND NOT deleted",
      [tokenId],
    );
    if (exists.rowCount === 0) {
      return null;
    }
    const { rows } = await this.pool.query<ApiTokenRequestRow>(
      `SELECT id, method, path, status_code, client_ip, user_agent,
              duration_ms, created_at
       FROM api_token_requests
       WHERE token_id = $1
         AND ($3::bigint IS NULL OR id < $3::bigint)
       ORDER BY id DESC
       LIMIT $2`,
      [tokenId, options.limit + 1, options.before],
    );
    const hasMore = rows.length > options.limit;
    const page = hasMore ? rows.slice(0, options.limit) : rows;
    return {
      requests: page.map(toSummary),
      has_more: hasMore,
      next_before: hasMore ? page[page.length - 1].id : null,
    };
  }
}
