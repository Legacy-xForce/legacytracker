import { ApiError, trackerFetch } from './tracker';

export type ApiTokenScope = 'read' | 'write';

export interface ApiToken {
    id: string;
    name: string;
    scope: ApiTokenScope;
    /** Non-secret label, e.g. `legacy-tracker-01a1…1289`. */
    hint: string;
    /** Addresses or CIDR prefixes allowed to use it; empty means any. */
    allowedIps: string[];
    createdAt: number;
    lastUsedAt: number | null;
    rotatedAt: number | null;
}

/** A token as the tracker-wide list shows it: the owner is named. */
export interface AuditedApiToken extends ApiToken {
    userId: string;
    userName: string;
}

/** A token as created or rotated: the only time its full value is known. */
export interface IssuedApiToken extends ApiToken {
    token: string;
}

export interface ApiTokenList {
    tokens: ApiToken[];
    /** The address the API is answering from, for one-click allowlisting. */
    yourIp: string | null;
}

/** One request made with a token, as its activity view shows it. */
export interface ApiTokenRequest {
    id: string;
    method: string;
    path: string;
    statusCode: number;
    clientIp: string | null;
    userAgent: string | null;
    durationMs: number | null;
    createdAt: number;
}

export interface ApiTokenRequestPage {
    requests: ApiTokenRequest[];
    hasMore: boolean;
    /** Pass back as `before` to fetch the next page; null on the last one. */
    nextBefore: string | null;
}

function time(value: unknown): number | null {
    if (typeof value !== 'string') return null;
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
}

export function parseApiToken(raw: unknown): ApiToken | null {
    const body = raw as Record<string, unknown> | null;
    if (!body || typeof body.id !== 'string' || (body.scope !== 'read' && body.scope !== 'write')) return null;
    return {
        id: body.id,
        name: typeof body.name === 'string' ? body.name : '',
        scope: body.scope,
        hint: typeof body.token_hint === 'string' ? body.token_hint : '',
        allowedIps: Array.isArray(body.allowed_ips)
            ? body.allowed_ips.filter((ip): ip is string => typeof ip === 'string')
            : [],
        createdAt: time(body.created_at) ?? 0,
        lastUsedAt: time(body.last_used_at),
        rotatedAt: time(body.rotated_at)
    };
}

/** Parses an entry of the everyone's-tokens list; owner fields are required. */
export function parseAuditedApiToken(raw: unknown): AuditedApiToken | null {
    const token = parseApiToken(raw);
    const body = raw as Record<string, unknown> | null;
    if (!token || !body) return null;
    if (typeof body.user_id !== 'string' || typeof body.user_name !== 'string') return null;
    return {
        ...token,
        userId: body.user_id,
        userName: body.user_name
    };
}

function integer(value: unknown): number | null {
    return typeof value === 'number' && Number.isInteger(value) ? value : null;
}

export function parseApiTokenRequest(raw: unknown): ApiTokenRequest | null {
    const body = raw as Record<string, unknown> | null;
    if (!body || (typeof body.id !== 'string' && typeof body.id !== 'number')) return null;
    if (typeof body.method !== 'string' || typeof body.path !== 'string') return null;
    const statusCode = integer(body.status_code);
    const createdAt = time(body.created_at);
    if (statusCode === null || createdAt === null) return null;
    return {
        id: String(body.id),
        method: body.method,
        path: body.path,
        statusCode,
        clientIp: typeof body.client_ip === 'string' ? body.client_ip : null,
        userAgent: typeof body.user_agent === 'string' ? body.user_agent : null,
        durationMs: integer(body.duration_ms),
        createdAt
    };
}

function parseIssued(raw: unknown): IssuedApiToken {
    const token = parseApiToken(raw);
    const value = (raw as { token?: unknown } | null)?.token;
    if (!token || typeof value !== 'string') throw new ApiError('Invalid token response.', 0);
    return { ...token, token: value };
}

/** Throws with the server's own message when it gave one ("…limit reached"). */
async function ensureOk(response: Response): Promise<void> {
    if (response.ok) return;
    const body = (await response.json().catch(() => null)) as { error?: unknown } | null;
    const message = typeof body?.error === 'string' ? body.error : `Tracker error (${response.status}).`;
    throw new ApiError(message, response.status);
}

export async function listApiTokens(): Promise<ApiTokenList> {
    const response = await trackerFetch('/api/v1/api-tokens');
    await ensureOk(response);
    const body = (await response.json()) as { tokens?: unknown; your_ip?: unknown };
    const tokens = Array.isArray(body.tokens)
        ? body.tokens.map(parseApiToken).filter((token): token is ApiToken => token !== null)
        : [];
    return { tokens, yourIp: typeof body.your_ip === 'string' ? body.your_ip : null };
}

/** Every live token on the tracker, ordered by owner. */
export async function listAllApiTokens(): Promise<AuditedApiToken[]> {
    const response = await trackerFetch('/api/v1/api-tokens/all');
    await ensureOk(response);
    const body = (await response.json()) as { tokens?: unknown };
    return Array.isArray(body.tokens)
        ? body.tokens.map(parseAuditedApiToken).filter((token): token is AuditedApiToken => token !== null)
        : [];
}

export async function createApiToken(name: string, scope: ApiTokenScope): Promise<IssuedApiToken> {
    const response = await trackerFetch('/api/v1/api-tokens', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ name, scope })
    });
    await ensureOk(response);
    return parseIssued(await response.json());
}

export async function rotateApiToken(id: string): Promise<IssuedApiToken> {
    const response = await trackerFetch(`/api/v1/api-tokens/${encodeURIComponent(id)}/rotate`, { method: 'POST' });
    await ensureOk(response);
    return parseIssued(await response.json());
}

/** Replaces the addresses a token may be used from; an empty list lifts the limit. */
export async function updateApiTokenAllowedIps(id: string, allowedIps: string[]): Promise<ApiToken> {
    const response = await trackerFetch(`/api/v1/api-tokens/${encodeURIComponent(id)}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ allowed_ips: allowedIps })
    });
    await ensureOk(response);
    const token = parseApiToken(await response.json());
    if (!token) throw new ApiError('Invalid token response.', 0);
    return token;
}

export async function deleteApiToken(id: string): Promise<void> {
    const response = await trackerFetch(`/api/v1/api-tokens/${encodeURIComponent(id)}`, { method: 'DELETE' });
    await ensureOk(response);
}

/** One page of a token's request trail, newest first. */
export async function listApiTokenRequests(
    id: string,
    options: { before?: string | null; limit?: number } = {}
): Promise<ApiTokenRequestPage> {
    const params = new URLSearchParams();
    if (options.before) params.set('before', options.before);
    if (options.limit) params.set('limit', String(options.limit));
    const query = params.toString();
    const response = await trackerFetch(
        `/api/v1/api-tokens/${encodeURIComponent(id)}/requests${query ? `?${query}` : ''}`
    );
    await ensureOk(response);
    const body = (await response.json()) as { requests?: unknown; has_more?: unknown; next_before?: unknown };
    const requests = Array.isArray(body.requests)
        ? body.requests.map(parseApiTokenRequest).filter((request): request is ApiTokenRequest => request !== null)
        : [];
    return {
        requests,
        hasMore: body.has_more === true,
        nextBefore: typeof body.next_before === 'string' ? body.next_before : null
    };
}
