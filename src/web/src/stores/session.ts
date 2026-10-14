import { defineStore } from 'pinia';
import { computed, ref } from 'vue';
import * as auth from '../api/auth';
import { AccountDisabledError, AuthRejectedError, type AuthTokens } from '../api/auth';
import { decodeJwt, hasScope } from '../lib/jwt';
import { storage } from '../lib/storage';

const STORAGE_KEY = 'legacytracker.session';
// Refresh a little early so a request never goes out with a token about to lapse.
const REFRESH_MARGIN_MS = 60_000;

interface StoredSession {
    refreshToken: string;
    refreshExpiresAt: number;
}

export type AccessDenial = 'accountDisabled' | 'missingScope';

function loadStored(): StoredSession | null {
    const raw = storage.get(STORAGE_KEY);
    if (!raw) return null;
    try {
        const stored = JSON.parse(raw) as Partial<StoredSession>;
        return typeof stored.refreshToken === 'string' && typeof stored.refreshExpiresAt === 'number'
            ? { refreshToken: stored.refreshToken, refreshExpiresAt: stored.refreshExpiresAt }
            : null;
    } catch {
        return null;
    }
}

export const useSessionStore = defineStore('session', () => {
    // The access token lives in memory only; the refresh token is what survives a reload.
    const tokens = ref<AuthTokens | null>(null);
    const accountDisabled = ref(false);
    // Set when the tracker server refuses a request the token's own claims allowed.
    const forbidden = ref(false);
    let refreshing: Promise<void> | null = null;

    const accessToken = computed(() => tokens.value?.accessToken ?? null);
    const isAuthenticated = computed(() => tokens.value !== null);
    const username = computed(() => {
        const claims = tokens.value ? decodeJwt(tokens.value.accessToken) : null;
        const name = claims?.username ?? claims?.preferred_username ?? claims?.sub;
        return typeof name === 'string' ? name : '';
    });
    const accessDenial = computed<AccessDenial | null>(() => {
        if (accountDisabled.value) return 'accountDisabled';
        if (forbidden.value) return 'missingScope';
        if (tokens.value && !hasScope(tokens.value.accessToken, 'tracker')) return 'missingScope';
        return null;
    });
    const hasCalendarScope = computed(() => !!tokens.value && hasScope(tokens.value.accessToken, 'calendar'));

    function adopt(next: AuthTokens) {
        tokens.value = next;
        accountDisabled.value = false;
        // A fresh token carries the account's current scopes, so give access another chance.
        forbidden.value = false;
        storage.set(
            STORAGE_KEY,
            JSON.stringify({ refreshToken: next.refreshToken, refreshExpiresAt: next.refreshExpiresAt })
        );
    }

    function clear() {
        tokens.value = null;
        forbidden.value = false;
        storage.remove(STORAGE_KEY);
    }

    function endSession(error: unknown) {
        clear();
        accountDisabled.value = error instanceof AccountDisabledError;
    }

    async function runRefresh(): Promise<void> {
        const stored = loadStored() ?? (tokens.value ? tokens.value : null);
        const refreshToken = stored?.refreshToken;
        if (!refreshToken) throw new AuthRejectedError('No session.', 401);
        try {
            adopt(await auth.refresh(refreshToken));
        } catch (error) {
            if (!(error instanceof AuthRejectedError) || error instanceof AccountDisabledError) throw error;
            // Refresh tokens rotate: another tab may have used this one and stored its successor.
            const successor = loadStored()?.refreshToken;
            if (!successor || successor === refreshToken) throw error;
            adopt(await auth.refresh(successor));
        }
    }

    /** Refreshes the session, sharing one request among concurrent callers. */
    function refresh(): Promise<void> {
        refreshing ??= runRefresh()
            .catch((error) => {
                // A network failure is transient: keep the session and let the caller retry.
                if (error instanceof AuthRejectedError) endSession(error);
                throw error;
            })
            .finally(() => {
                refreshing = null;
            });
        return refreshing;
    }

    /** Resumes a session from the stored refresh token. Returns whether one is active. */
    async function restore(): Promise<boolean> {
        const stored = loadStored();
        if (!stored || stored.refreshExpiresAt <= Date.now()) {
            clear();
            return false;
        }
        try {
            await refresh();
        } catch {
            return false;
        }
        return isAuthenticated.value;
    }

    async function login(name: string, password: string): Promise<void> {
        try {
            adopt(await auth.login(name.trim(), password));
        } catch (error) {
            if (error instanceof AccountDisabledError) endSession(error);
            throw error;
        }
    }

    async function logout(): Promise<void> {
        const refreshToken = tokens.value?.refreshToken;
        clear();
        accountDisabled.value = false;
        if (refreshToken) await auth.logout(refreshToken);
    }

    function markForbidden() {
        forbidden.value = true;
    }

    /** A valid access token, refreshing first when it is about to expire. Null when signed out. */
    async function getAccessToken(): Promise<string | null> {
        if (tokens.value && tokens.value.expiresAt - Date.now() < REFRESH_MARGIN_MS) {
            try {
                await refresh();
            } catch {
                // Rejected: the session is already cleared. Transient: use what we have.
            }
        }
        return tokens.value?.accessToken ?? null;
    }

    return {
        accessToken,
        isAuthenticated,
        username,
        accessDenial,
        hasCalendarScope,
        restore,
        login,
        logout,
        refresh,
        getAccessToken,
        markForbidden
    };
});
