import { LEGACY_KEY, useSessionStore } from '../stores/session';
export function b64url(value: unknown): string {
    return btoa(JSON.stringify(value)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fakeJwt(claims: Record<string, unknown>): string {
    return `${b64url({ alg: 'ES256' })}.${b64url(claims)}.sig`;
}

export function tokenResponse(access: string, refresh = 'refresh-1') {
    return { access_token: access, refresh_token: refresh, expires_in: 900, refresh_expires_in: 86400 };
}

export function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

/**
 * Starts a session in tests: stores a (legacy) refresh token and restores it, so the caller's
 * next mocked fetch response is the token response.
 */
export async function startSession(): Promise<void> {
    localStorage.setItem(
        LEGACY_KEY,
        JSON.stringify({ refreshToken: 'stored-refresh', refreshExpiresAt: Date.now() + 86_400_000 })
    );
    await useSessionStore().restore();
}
