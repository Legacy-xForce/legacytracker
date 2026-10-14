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
