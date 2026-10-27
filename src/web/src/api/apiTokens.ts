import { ApiError, trackerFetch } from './tracker';

export type ApiTokenScope = 'read' | 'write';

export interface ApiToken {
    id: string;
    name: string;
    scope: ApiTokenScope;
    /** Non-secret label, e.g. `legacy-tracker-01a1…1289`. */
    hint: string;
    createdAt: number;
    lastUsedAt: number | null;
    rotatedAt: number | null;
}

/** A token as created or rotated: the only time its full value is known. */
export interface IssuedApiToken extends ApiToken {
    token: string;
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
        createdAt: time(body.created_at) ?? 0,
        lastUsedAt: time(body.last_used_at),
        rotatedAt: time(body.rotated_at)
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

export async function listApiTokens(): Promise<ApiToken[]> {
    const response = await trackerFetch('/api/v1/api-tokens');
    await ensureOk(response);
    const tokens = ((await response.json()) as { tokens?: unknown } | null)?.tokens;
    if (!Array.isArray(tokens)) return [];
    return tokens.map(parseApiToken).filter((token): token is ApiToken => token !== null);
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

export async function deleteApiToken(id: string): Promise<void> {
    const response = await trackerFetch(`/api/v1/api-tokens/${encodeURIComponent(id)}`, { method: 'DELETE' });
    await ensureOk(response);
}
