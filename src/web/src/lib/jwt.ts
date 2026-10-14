export type JwtPayload = Record<string, unknown>;

/** The claims of a JWT, or null when it isn't one. The signature is not checked; servers do that. */
export function decodeJwt(token: string): JwtPayload | null {
    const part = token.split('.')[1];
    if (!part) return null;
    try {
        const base64 = part.replace(/-/g, '+').replace(/_/g, '/');
        const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
        const payload: unknown = JSON.parse(new TextDecoder().decode(bytes));
        return payload !== null && typeof payload === 'object' ? (payload as JwtPayload) : null;
    } catch {
        return null;
    }
}

/** Legacy Auth puts per-app permissions in `scopes: { tracker: true, calendar: true }`. */
export function hasScope(token: string, scope: string): boolean {
    const scopes = decodeJwt(token)?.scopes;
    return typeof scopes === 'object' && scopes !== null && (scopes as Record<string, unknown>)[scope] === true;
}
