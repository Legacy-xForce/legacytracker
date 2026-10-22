import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { signInUrl } from '../api/oidc';
import { redirectTo } from '../lib/redirect';
import { LEGACY_KEY, SESSION_ENDED_MESSAGE, STORAGE_KEY, useSessionStore } from '../stores/session';
import { b64url, fakeJwt, jsonResponse, tokenResponse } from './helpers';

vi.mock('../lib/redirect', () => ({ redirectTo: vi.fn() }));

// jsdom's ArrayBuffer isn't Node's, so oauth4webapi can't tell the digest is one; hand it bytes.
const digest = crypto.subtle.digest.bind(crypto.subtle);
vi.spyOn(crypto.subtle, 'digest').mockImplementation(
    async (algorithm, data) => new Uint8Array(await digest(algorithm, data)) as unknown as ArrayBuffer
);

const ISSUER = 'https://auth.legacy-group.tech';
const ORIGIN = window.location.origin;

const trackerToken = fakeJwt({ sub: 'u1', username: 'ada', aud: 'tracker', scopes: { tracker: true, calendar: true } });
const noCalendarToken = fakeJwt({ sub: 'u1', username: 'ada', aud: 'tracker', scopes: { tracker: true } });
const calendarToken = fakeJwt({ sub: 'u1', aud: 'calendar' });

type TokenHandler = (params: URLSearchParams) => Response | Promise<Response>;

let fetchMock: ReturnType<typeof vi.fn>;
let tokenHandler: TokenHandler;
let tokenRequests: URLSearchParams[];

function idToken(nonce: string): string {
    const now = Math.floor(Date.now() / 1000);
    return `${b64url({ alg: 'ES256' })}.${b64url({ iss: ISSUER, aud: 'tracker-spa', sub: 'u1', nonce, iat: now, exp: now + 600 })}.sig`;
}

function grantResponse(access: string, refresh: string, extra: Record<string, unknown> = {}) {
    return jsonResponse({
        access_token: access,
        refresh_token: refresh,
        token_type: 'Bearer',
        expires_in: 900,
        ...extra
    });
}

function oauthError(error: string, status = 400) {
    return jsonResponse({ error, error_description: error }, status);
}

function storeGrant(refreshToken: string, calendar = true) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ refreshToken, idToken: 'id-token', calendar }));
}

function storedRefreshToken(): string | undefined {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? (JSON.parse(raw) as { refreshToken: string }).refreshToken : undefined;
}

/** A token endpoint that rotates: only the newest refresh token works, like the OP's. */
function rotatingTokenEndpoint(first: string, access = trackerToken) {
    let current = first;
    let n = 0;
    return (params: URLSearchParams) => {
        if (params.get('refresh_token') !== current) return oauthError('invalid_grant');
        current = `rt-${++n}`;
        return grantResponse(params.get('resource') === 'urn:legacy:calendar' ? calendarToken : access, current);
    };
}

beforeEach(() => {
    localStorage.clear();
    sessionStorage.clear();
    setActivePinia(createPinia());
    vi.mocked(redirectTo).mockReset();
    tokenRequests = [];
    tokenHandler = () => oauthError('invalid_grant');
    fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(input instanceof Request ? input.url : String(input));
        if (url.pathname === '/.well-known/openid-configuration') {
            return jsonResponse({
                issuer: ISSUER,
                authorization_endpoint: `${ISSUER}/authorize`,
                token_endpoint: `${ISSUER}/token`,
                end_session_endpoint: `${ISSUER}/logout`,
                jwks_uri: `${ISSUER}/.well-known/jwks.json`
            });
        }
        if (url.pathname === '/token') {
            const params = new URLSearchParams(String(init?.body ?? ''));
            tokenRequests.push(params);
            return tokenHandler(params);
        }
        throw new TypeError(`unexpected fetch ${url}`);
    });
    vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => vi.unstubAllGlobals());

/** Starts a sign-in and returns the authorize URL plus the callback the OP would send back. */
async function authorize(calendar = true) {
    const url = new URL(await signInUrl('/somewhere', calendar));
    const state = url.searchParams.get('state')!;
    const nonce = url.searchParams.get('nonce')!;
    return {
        url,
        nonce,
        success: new URL(`${ORIGIN}/callback?code=the-code&state=${state}`),
        denied: new URL(`${ORIGIN}/callback?error=access_denied&state=${state}`),
        forged: new URL(`${ORIGIN}/callback?code=the-code&state=someone-else`)
    };
}

describe('signing in through the OP', () => {
    it('asks for one grant covering the tracker and the calendar, with PKCE', async () => {
        const { url } = await authorize();

        expect(url.origin + url.pathname).toBe(`${ISSUER}/authorize`);
        expect(url.searchParams.get('client_id')).toBe('tracker-spa');
        expect(url.searchParams.get('redirect_uri')).toBe(`${ORIGIN}/callback`);
        expect(url.searchParams.get('response_type')).toBe('code');
        expect(url.searchParams.get('scope')).toBe(
            'openid profile offline_access tracker.read tracker.write calendar.read'
        );
        expect(url.searchParams.get('prompt')).toBe('consent');
        expect(url.searchParams.get('code_challenge_method')).toBe('S256');
        expect(url.searchParams.get('code_challenge')).toMatch(/^[\w-]{43}$/);
        expect(url.searchParams.getAll('resource')).toEqual(['urn:legacy:tracker', 'urn:legacy:calendar']);
    });

    it('leaves the calendar out when told to', async () => {
        const { url } = await authorize(false);

        expect(url.searchParams.get('scope')).not.toContain('calendar');
        expect(url.searchParams.getAll('resource')).toEqual(['urn:legacy:tracker']);
    });

    it('exchanges the code for a tracker token and keeps only the grant', async () => {
        const { success, nonce } = await authorize();
        tokenHandler = () => grantResponse(trackerToken, 'rt-0', { id_token: idToken(nonce) });
        const session = useSessionStore();

        expect(await session.completeSignIn(success)).toBe('/somewhere');

        const [exchange] = tokenRequests;
        expect(exchange.get('grant_type')).toBe('authorization_code');
        expect(exchange.get('code')).toBe('the-code');
        expect(exchange.get('code_verifier')).toMatch(/^[\w-]{43}$/);
        expect(exchange.get('resource')).toBe('urn:legacy:tracker');
        expect(exchange.get('client_id')).toBe('tracker-spa');
        expect(session.isAuthenticated).toBe(true);
        expect(session.username).toBe('ada');
        expect(session.hasCalendarScope).toBe(true);
        const stored = localStorage.getItem(STORAGE_KEY)!;
        expect(JSON.parse(stored)).toMatchObject({ refreshToken: 'rt-0', calendar: true });
        expect(stored).not.toContain(trackerToken);
    });

    it('refuses a callback whose state is not ours', async () => {
        const { forged } = await authorize();
        const session = useSessionStore();

        expect(await session.completeSignIn(forged)).toBe('/login');
        expect(tokenRequests).toHaveLength(0);
        expect(session.isAuthenticated).toBe(false);
        expect(session.signInError).toBe('Sign-in failed. Please try again.');
    });

    it('refuses an ID token with the wrong nonce', async () => {
        const { success } = await authorize();
        tokenHandler = () => grantResponse(trackerToken, 'rt-0', { id_token: idToken('another') });
        const session = useSessionStore();

        expect(await session.completeSignIn(success)).toBe('/login');
        expect(session.isAuthenticated).toBe(false);
        expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
    });

    it('asks again without the calendar when the OP denies the sign-in', async () => {
        const { denied } = await authorize(true);
        const session = useSessionStore();

        expect(await session.completeSignIn(denied)).toBeNull();

        const retry = new URL(vi.mocked(redirectTo).mock.calls[0][0]);
        expect(retry.searchParams.getAll('resource')).toEqual(['urn:legacy:tracker']);
        expect(retry.searchParams.get('scope')).not.toContain('calendar');
    });

    it('explains a denial for the tracker itself', async () => {
        const { denied } = await authorize(false);
        const session = useSessionStore();

        expect(await session.completeSignIn(denied)).toBe('/login');
        expect(session.signInError).toBe("This account can't use Legacy Tracker.");
        expect(redirectTo).not.toHaveBeenCalled();
    });

    it('treats a callback without a pending sign-in as expired', async () => {
        const session = useSessionStore();

        expect(await session.completeSignIn(new URL(`${ORIGIN}/callback?code=x&state=y`))).toBe('/login');
        expect(session.signInError).toBe('The sign-in expired. Please try again.');
    });
});

describe('the OP session', () => {
    it('restores from the stored grant and stores the rotated token', async () => {
        storeGrant('rt-0');
        tokenHandler = rotatingTokenEndpoint('rt-0');
        const session = useSessionStore();

        expect(await session.restore()).toBe(true);
        expect(tokenRequests[0].get('grant_type')).toBe('refresh_token');
        expect(tokenRequests[0].get('resource')).toBe('urn:legacy:tracker');
        expect(storedRefreshToken()).toBe('rt-1');
        expect(session.accessToken).toBe(trackerToken);
    });

    it('signs out when the OP refuses the grant', async () => {
        storeGrant('revoked');
        const session = useSessionStore();

        expect(await session.restore()).toBe(false);
        expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
        expect(session.signInError).toBe(SESSION_ENDED_MESSAGE);
    });

    it('keeps the grant when the OP is unreachable', async () => {
        storeGrant('rt-0');
        tokenHandler = () => {
            throw new TypeError('offline');
        };
        const session = useSessionStore();

        expect(await session.restore()).toBe(false);
        expect(storedRefreshToken()).toBe('rt-0');
    });

    it('never lets two tabs refresh with the same token', async () => {
        storeGrant('rt-0');
        tokenHandler = rotatingTokenEndpoint('rt-0');
        // Two tabs: separate stores (memory), one localStorage.
        const tabA = useSessionStore(createPinia());
        const tabB = useSessionStore(createPinia());

        const [a, b] = await Promise.all([tabA.restore(), tabB.restore()]);

        expect([a, b]).toEqual([true, true]);
        expect(tokenRequests.map((params) => params.get('refresh_token'))).toEqual(['rt-0', 'rt-1']);
        expect(storedRefreshToken()).toBe('rt-2');
    });

    it('follows another tab signing out', async () => {
        storeGrant('rt-0');
        tokenHandler = rotatingTokenEndpoint('rt-0');
        const session = useSessionStore();
        await session.restore();

        localStorage.removeItem(STORAGE_KEY);
        window.dispatchEvent(
            new StorageEvent('storage', { key: STORAGE_KEY, newValue: null, storageArea: localStorage })
        );

        expect(session.isAuthenticated).toBe(false);
    });

    it('signs out at the OP with the ID token as hint', async () => {
        storeGrant('rt-0');
        tokenHandler = rotatingTokenEndpoint('rt-0');
        const session = useSessionStore();
        await session.restore();

        await session.logout();

        expect(session.isAuthenticated).toBe(false);
        expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
        const url = new URL(vi.mocked(redirectTo).mock.calls[0][0]);
        expect(url.origin + url.pathname).toBe(`${ISSUER}/logout`);
        expect(url.searchParams.get('id_token_hint')).toBe('id-token');
        expect(url.searchParams.get('post_logout_redirect_uri')).toBe(`${ORIGIN}/`);
    });

    it('ends when the server says the session signed out', async () => {
        storeGrant('rt-0');
        tokenHandler = rotatingTokenEndpoint('rt-0');
        const session = useSessionStore();
        await session.restore();

        session.expire();

        expect(session.isAuthenticated).toBe(false);
        expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
        expect(session.signInError).toBe(SESSION_ENDED_MESSAGE);
    });
});

describe('the calendar token', () => {
    it('comes from the same grant and rotates its refresh token', async () => {
        storeGrant('rt-0');
        tokenHandler = rotatingTokenEndpoint('rt-0');
        const session = useSessionStore();
        await session.restore();

        expect(await session.getCalendarToken()).toBe(calendarToken);
        expect(tokenRequests[1].get('resource')).toBe('urn:legacy:calendar');
        expect(tokenRequests[1].get('refresh_token')).toBe('rt-1');
        expect(storedRefreshToken()).toBe('rt-2');
        // Cached while fresh.
        expect(await session.getCalendarToken()).toBe(calendarToken);
        expect(tokenRequests).toHaveLength(2);
    });

    it('is not asked for when the account has no calendar', async () => {
        storeGrant('rt-0');
        tokenHandler = rotatingTokenEndpoint('rt-0', noCalendarToken);
        const session = useSessionStore();
        await session.restore();

        expect(session.hasCalendarScope).toBe(false);
        expect(await session.getCalendarToken()).toBeNull();
        expect(tokenRequests).toHaveLength(1);
    });

    it('is not asked for when the grant left the calendar out', async () => {
        storeGrant('rt-0', false);
        tokenHandler = rotatingTokenEndpoint('rt-0');
        const session = useSessionStore();
        await session.restore();

        expect(session.hasCalendarScope).toBe(false);
        expect(await session.getCalendarToken()).toBeNull();
    });

    it('a refusal hides the calendar without ending the session at once', async () => {
        storeGrant('rt-0');
        const rotate = rotatingTokenEndpoint('rt-0');
        tokenHandler = (params) =>
            params.get('resource') === 'urn:legacy:calendar' ? oauthError('invalid_target') : rotate(params);
        const session = useSessionStore();
        await session.restore();

        expect(await session.getCalendarToken()).toBeNull();
        expect(session.hasCalendarScope).toBe(false);
        expect(session.isAuthenticated).toBe(true);
        expect(await session.getCalendarToken()).toBeNull();
        expect(tokenRequests).toHaveLength(2);
    });

    it('a network failure is an error, not a refusal', async () => {
        storeGrant('rt-0');
        const rotate = rotatingTokenEndpoint('rt-0');
        tokenHandler = (params) => {
            if (params.get('resource') === 'urn:legacy:calendar') throw new TypeError('offline');
            return rotate(params);
        };
        const session = useSessionStore();
        await session.restore();

        await expect(session.getCalendarToken()).rejects.toThrow('Unable to reach the sign-in server.');
        expect(session.hasCalendarScope).toBe(true);
    });
});

describe('a session from the old password login', () => {
    function storeLegacy(refreshToken: string, refreshExpiresAt = Date.now() + 60_000) {
        localStorage.setItem(LEGACY_KEY, JSON.stringify({ refreshToken, refreshExpiresAt }));
    }

    function legacyRefreshes(response: () => Response) {
        fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
            expect(String(input)).toBe(`${ISSUER}/auth/refresh`);
            return response();
        });
    }

    it('keeps refreshing through /auth/refresh', async () => {
        storeLegacy('old');
        legacyRefreshes(() => jsonResponse(tokenResponse(trackerToken, 'rotated')));
        const session = useSessionStore();

        expect(await session.restore()).toBe(true);
        expect(JSON.parse(fetchMock.mock.calls[0][1].body as string)).toEqual({ refresh_token: 'old' });
        expect(localStorage.getItem(LEGACY_KEY)).toContain('rotated');
        // Its token is addressed to both apps.
        expect(await session.getCalendarToken()).toBe(trackerToken);
    });

    it('ends for good when it fails, so the next sign-in uses the OP', async () => {
        storeLegacy('old');
        legacyRefreshes(() => jsonResponse({ error: 'Invalid or revoked refresh token' }, 401));
        const session = useSessionStore();

        expect(await session.restore()).toBe(false);
        expect(localStorage.getItem(LEGACY_KEY)).toBeNull();
        expect(session.signInError).toBe(SESSION_ENDED_MESSAGE);
    });

    it('explains a disabled account', async () => {
        storeLegacy('old');
        legacyRefreshes(() => jsonResponse({ error: 'Account disabled' }, 403));
        const session = useSessionStore();

        expect(await session.restore()).toBe(false);
        expect(session.signInError).toBe('This account has been disabled.');
    });

    it('ends when the account lost the tracker scope', async () => {
        storeLegacy('old');
        legacyRefreshes(() => jsonResponse(tokenResponse(fakeJwt({ sub: 'u1', scopes: { calendar: true } }))));
        const session = useSessionStore();

        expect(await session.restore()).toBe(false);
        expect(session.signInError).toBe("This account can't use Legacy Tracker.");
    });

    it('is replaced by an OP sign-in', async () => {
        storeLegacy('old');
        const { success, nonce } = await authorize();
        tokenHandler = () => grantResponse(trackerToken, 'rt-0', { id_token: idToken(nonce) });
        const session = useSessionStore();

        await session.completeSignIn(success);

        expect(localStorage.getItem(LEGACY_KEY)).toBeNull();
        expect(storedRefreshToken()).toBe('rt-0');
    });

    it('does not restore an expired one', async () => {
        storeLegacy('old', Date.now() - 1);
        const session = useSessionStore();

        expect(await session.restore()).toBe(false);
        expect(fetchMock).not.toHaveBeenCalled();
    });
});
