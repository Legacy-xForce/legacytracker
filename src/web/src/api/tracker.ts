import { config } from '../config';
import { useSessionStore } from '../stores/session';

/** A tracker request the server refused or that couldn't be made. `status` is 0 when unreachable. */
export class ApiError extends Error {
    constructor(
        message: string,
        readonly status: number
    ) {
        super(message);
    }
}

async function send(path: string, init: RequestInit, token: string): Promise<Response> {
    try {
        return await fetch(config.backendUrl + path, {
            ...init,
            headers: { ...init.headers, authorization: `Bearer ${token}` }
        });
    } catch {
        throw new ApiError('Unable to reach the tracker.', 0);
    }
}

/** A 403 that means "that person hides from you", not "you may not use the tracker". */
async function isNotSharing(response: Response): Promise<boolean> {
    const body = (await response
        .clone()
        .json()
        .catch(() => null)) as { error?: unknown } | null;
    return body?.error === 'not_sharing';
}

/** A tracker request with the user's access token, retried once with a fresh token after a 401. */
export async function trackerFetch(path: string, init: RequestInit = {}): Promise<Response> {
    const session = useSessionStore();
    const token = await session.getAccessToken();
    if (!token) throw new ApiError('Not signed in.', 401);

    let response = await send(path, init, token);
    if (response.status === 401) {
        try {
            await session.refresh();
        } catch {
            throw new ApiError('Session expired.', 401);
        }
        const fresh = await session.getAccessToken();
        if (!fresh) throw new ApiError('Session expired.', 401);
        response = await send(path, init, fresh);
    }
    if (response.status === 403 && !(await isNotSharing(response))) {
        // The server is stricter than the token's own claims (it re-checks the scope).
        session.markForbidden();
        throw new ApiError('Access denied.', 403);
    }
    return response;
}

export async function trackerJson<T>(path: string, init: RequestInit = {}): Promise<T> {
    const response = await trackerFetch(path, init);
    if (!response.ok) throw new ApiError(`Tracker error (${response.status}).`, response.status);
    return (await response.json()) as T;
}

/** A one-time ticket that lets the browser open the stream (it can't set headers on a WebSocket). */
export async function requestStreamTicket(): Promise<string> {
    const body = await trackerJson<{ ticket?: unknown }>('/api/v1/streams/ticket', { method: 'POST' });
    if (typeof body.ticket !== 'string' || body.ticket === '') throw new ApiError('Invalid ticket response.', 0);
    return body.ticket;
}
