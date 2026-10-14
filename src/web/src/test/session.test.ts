import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AccountDisabledError, AuthError } from '../api/auth';
import { useSessionStore } from '../stores/session';
import { fakeJwt, jsonResponse, tokenResponse } from './helpers';

const STORAGE_KEY = 'legacytracker.session';
const trackerToken = fakeJwt({ sub: 'u1', username: 'ada', scopes: { tracker: true, calendar: true } });
const noScopeToken = fakeJwt({ sub: 'u1', username: 'ada', scopes: { calendar: true } });

let fetchMock: ReturnType<typeof vi.fn>;

function bodyOf(call: number): Record<string, unknown> {
    return JSON.parse(fetchMock.mock.calls[call][1].body as string);
}

function storeSession(refreshToken: string, refreshExpiresAt = Date.now() + 60_000) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ refreshToken, refreshExpiresAt }));
}

beforeEach(() => {
    localStorage.clear();
    setActivePinia(createPinia());
    fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => vi.unstubAllGlobals());

describe('session store', () => {
    it('signs in, exposes the account and keeps only the refresh token', async () => {
        fetchMock.mockResolvedValue(jsonResponse(tokenResponse(trackerToken)));
        const session = useSessionStore();

        await session.login(' ada ', 'pw');

        expect(bodyOf(0)).toEqual({ username: 'ada', password: 'pw' });
        expect(session.isAuthenticated).toBe(true);
        expect(session.username).toBe('ada');
        expect(session.accessDenial).toBeNull();
        expect(session.hasCalendarScope).toBe(true);
        const stored = localStorage.getItem(STORAGE_KEY)!;
        expect(stored).toContain('refresh-1');
        expect(stored).not.toContain(trackerToken);
    });

    it('reports a wrong password without starting a session', async () => {
        fetchMock.mockResolvedValue(jsonResponse({ error: 'Invalid credentials' }, 401));
        const session = useSessionStore();

        await expect(session.login('ada', 'bad')).rejects.toThrow('Wrong username or password.');
        expect(session.isAuthenticated).toBe(false);
    });

    it('flags an account without the tracker scope', async () => {
        fetchMock.mockResolvedValue(jsonResponse(tokenResponse(noScopeToken)));
        const session = useSessionStore();

        await session.login('ada', 'pw');

        expect(session.accessDenial).toBe('missingScope');
    });

    it('flags a disabled account and ends the session', async () => {
        fetchMock.mockResolvedValue(jsonResponse({ error: 'Account disabled' }, 403));
        const session = useSessionStore();

        await expect(session.login('ada', 'pw')).rejects.toBeInstanceOf(AccountDisabledError);
        expect(session.accessDenial).toBe('accountDisabled');
        expect(session.isAuthenticated).toBe(false);
    });

    it('restores a stored session through the refresh token', async () => {
        storeSession('stored-refresh');
        fetchMock.mockResolvedValue(jsonResponse(tokenResponse(trackerToken, 'rotated')));
        const session = useSessionStore();

        expect(await session.restore()).toBe(true);
        expect(bodyOf(0)).toEqual({ refresh_token: 'stored-refresh' });
        expect(localStorage.getItem(STORAGE_KEY)).toContain('rotated');
    });

    it('does not restore an expired session', async () => {
        storeSession('old', Date.now() - 1);
        const session = useSessionStore();

        expect(await session.restore()).toBe(false);
        expect(fetchMock).not.toHaveBeenCalled();
        expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
    });

    it('drops the session when the refresh token is rejected', async () => {
        storeSession('revoked');
        fetchMock.mockResolvedValue(jsonResponse({ error: 'Invalid or revoked refresh token' }, 401));
        const session = useSessionStore();

        expect(await session.restore()).toBe(false);
        expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
    });

    it('keeps the stored session when the network is down', async () => {
        storeSession('still-good');
        fetchMock.mockRejectedValue(new TypeError('offline'));
        const session = useSessionStore();

        expect(await session.restore()).toBe(false);
        expect(localStorage.getItem(STORAGE_KEY)).toContain('still-good');
    });

    it("retries with another tab's rotated refresh token", async () => {
        storeSession('first');
        const session = useSessionStore();
        fetchMock.mockImplementationOnce(async () => {
            // Meanwhile another tab used 'first' and stored its successor.
            storeSession('second');
            return jsonResponse({ error: 'Invalid or revoked refresh token' }, 401);
        });
        fetchMock.mockResolvedValueOnce(jsonResponse(tokenResponse(trackerToken, 'third')));

        expect(await session.restore()).toBe(true);
        expect(bodyOf(1)).toEqual({ refresh_token: 'second' });
    });

    it('shares one refresh among concurrent callers', async () => {
        fetchMock.mockResolvedValueOnce(jsonResponse(tokenResponse(trackerToken)));
        const session = useSessionStore();
        await session.login('ada', 'pw');
        fetchMock.mockClear();
        fetchMock.mockResolvedValue(jsonResponse(tokenResponse(trackerToken, 'next')));

        await Promise.all([session.refresh(), session.refresh(), session.refresh()]);

        expect(fetchMock).toHaveBeenCalledTimes(1);
    });

    it('refreshes an access token that is about to expire', async () => {
        const short = { ...tokenResponse(trackerToken), expires_in: 30 };
        fetchMock.mockResolvedValueOnce(jsonResponse(short));
        const session = useSessionStore();
        await session.login('ada', 'pw');
        const fresh = fakeJwt({ sub: 'u1', scopes: { tracker: true }, fresh: true });
        fetchMock.mockResolvedValueOnce(jsonResponse(tokenResponse(fresh, 'next')));

        expect(await session.getAccessToken()).toBe(fresh);
    });

    it('signs out locally and revokes the refresh token', async () => {
        fetchMock.mockResolvedValueOnce(jsonResponse(tokenResponse(trackerToken)));
        const session = useSessionStore();
        await session.login('ada', 'pw');
        fetchMock.mockResolvedValueOnce(jsonResponse({ success: true }));

        await session.logout();

        expect(session.isAuthenticated).toBe(false);
        expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
        expect(bodyOf(1)).toEqual({ refresh_token: 'refresh-1' });
    });

    it('treats an unreachable server as a plain AuthError', async () => {
        fetchMock.mockRejectedValue(new TypeError('offline'));
        const session = useSessionStore();

        await expect(session.login('ada', 'pw')).rejects.toBeInstanceOf(AuthError);
    });
});
