import type { Pool } from "pg";

/** Trailers are informational, so keep a bound on what the table stores. */
export const MAX_USER_AGENT_LENGTH = 512;

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
 * Persistent trail of requests made with personal API tokens, so an owner can
 * see what an integration did and security can investigate a leaked token.
 * Rows include requests the token's scope or address allowlist turned away.
 * A deleted token leaves its history behind (`token_id` becomes null).
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
}
