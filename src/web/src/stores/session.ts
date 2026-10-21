import { defineStore } from 'pinia';
import { computed, ref, shallowRef } from 'vue';
import * as legacy from '../api/auth';
import { AuthError, AuthRejectedError } from '../api/auth';
import * as oidc from '../api/oidc';
import { CALENDAR_RESOURCE, SignInDeniedError, TRACKER_RESOURCE, type AccessGrant } from '../api/oidc';
import { decodeJwt, hasScope } from '../lib/jwt';
import { withRefreshLock } from '../lib/lock';
import { redirectTo } from '../lib/redirect';
import { storage } from '../lib/storage';

// The OP grant: refresh token, ID token (sign-out hint) and whether it covers the calendar.
export const STORAGE_KEY = 'legacytracker.oidc';
// A session from the old password login. It keeps refreshing through `/auth/refresh` until that
// fails; the next sign-in goes through the OP (docs/oidc-migration.md, decision 3).
export const LEGACY_KEY = 'legacytracker.session';
// Refresh a little early so a request never goes out with a token about to lapse.
const REFRESH_MARGIN_MS = 60_000;

export const NO_ACCESS_MESSAGE = "This account can't use Legacy Tracker.";

interface StoredGrant {
    refreshToken: string;
    idToken: string | null;
    calendar: boolean;
}

interface LegacySession {
    refreshToken: string;
    refreshExpiresAt: number;
}

function readJson(key: string): Record<string, unknown> | null {
    const raw = storage.get(key);
    if (!raw) return null;
    try {
        const value: unknown = JSON.parse(raw);
        return value !== null && typeof value === 'object' ? (value as Record<string, unknown>) : null;
    } catch {
        return null;
    }
}

function loadGrant(): StoredGrant | null {
    const stored = readJson(STORAGE_KEY);
    if (typeof stored?.refreshToken !== 'string') return null;
    return {
        refreshToken: stored.refreshToken,
        idToken: typeof stored.idToken === 'string' ? stored.idToken : null,
        calendar: stored.calendar === true
    };
}

function saveGrant(grant: StoredGrant) {
    storage.set(STORAGE_KEY, JSON.stringify(grant));
}

function loadLegacy(): LegacySession | null {
    const stored = readJson(LEGACY_KEY);
    return typeof stored?.refreshToken === 'string' && typeof stored.refreshExpiresAt === 'number'
        ? { refreshToken: stored.refreshToken, refreshExpiresAt: stored.refreshExpiresAt }
        : null;
}

function isFresh(grant: AccessGrant | null): grant is AccessGrant {
    return !!grant && grant.expiresAt - Date.now() >= REFRESH_MARGIN_MS;
}

/** The message a refused session leaves on the sign-in screen, if any. */
function endMessage(error: unknown): string | null {
    // 403s say why (disabled account, no tracker access); a revoked or expired grant just ends.
    return error instanceof AuthRejectedError && error.status === 403 ? error.message : null;
}

export const useSessionStore = defineStore('session', () => {
    // Access tokens live in memory only; the refresh token is what survives a reload.
    const tracker = shallowRef<AccessGrant | null>(null);
    const calendar = shallowRef<AccessGrant | null>(null);
    // The grant was asked for the calendar too.
    const grantHasCalendar = ref(false);
    // The OP refused a calendar token: stop asking.
    const calendarRefused = ref(false);
    const legacyMode = ref(false);
    /** Shown on the sign-in screen: why the last sign-in or session ended. */
    const signInError = ref<string | null>(null);
    let refreshing: Promise<void> | null = null;
    let calendarRefreshing: Promise<string | null> | null = null;

    const accessToken = computed(() => tracker.value?.accessToken ?? null);
    const isAuthenticated = computed(() => tracker.value !== null);
    const username = computed(() => {
        const claims = tracker.value ? decodeJwt(tracker.value.accessToken) : null;
        const name = claims?.username ?? claims?.preferred_username ?? claims?.sub;
        return typeof name === 'string' ? name : '';
    });
    // The tracker token's `scopes` claim is read fresh at every issuance, so it says whether a
    // calendar token can be had *before* asking: a refused refresh spends the refresh token.
    const hasCalendarScope = computed(() => {
        if (!tracker.value || !hasScope(tracker.value.accessToken, 'calendar')) return false;
        return legacyMode.value || (grantHasCalendar.value && !calendarRefused.value);
    });

    function adoptTracker(next: AccessGrant) {
        tracker.value = { accessToken: next.accessToken, expiresAt: next.expiresAt };
        signInError.value = null;
    }

    function clear() {
        tracker.value = null;
        calendar.value = null;
        grantHasCalendar.value = false;
        calendarRefused.value = false;
        legacyMode.value = false;
        storage.remove(STORAGE_KEY);
        storage.remove(LEGACY_KEY);
    }

    /** Ends the session here, leaving `message` for the sign-in screen. */
    function endSession(message: string | null = null) {
        clear();
        signInError.value = message;
    }

    async function refreshOidc(): Promise<void> {
        await withRefreshLock(async () => {
            // Read inside the lock: another tab may have rotated the token or signed out.
            const stored = loadGrant();
            if (!stored) throw new AuthRejectedError('No session.', 401);
            const next = await oidc.refreshGrant(stored.refreshToken, TRACKER_RESOURCE);
            saveGrant({ ...stored, refreshToken: next.refreshToken });
            grantHasCalendar.value = stored.calendar;
            adoptTracker(next);
        });
    }

    async function refreshLegacy(): Promise<void> {
        const adopt = (next: legacy.AuthTokens) => {
            if (!hasScope(next.accessToken, 'tracker')) {
                throw new AuthRejectedError(NO_ACCESS_MESSAGE, 403);
            }
            storage.set(
                LEGACY_KEY,
                JSON.stringify({ refreshToken: next.refreshToken, refreshExpiresAt: next.refreshExpiresAt })
            );
            adoptTracker(next);
        };
        const refreshToken = loadLegacy()?.refreshToken;
        if (!refreshToken) throw new AuthRejectedError('No session.', 401);
        try {
            adopt(await legacy.refresh(refreshToken));
        } catch (error) {
            if (!(error instanceof AuthRejectedError) || error.status === 403) throw error;
            // Refresh tokens rotate: another tab may have used this one and stored its successor.
            const successor = loadLegacy()?.refreshToken;
            if (!successor || successor === refreshToken) throw error;
            adopt(await legacy.refresh(successor));
        }
    }

    /** Refreshes the tracker token, sharing one request among concurrent callers. */
    function refresh(): Promise<void> {
        refreshing ??= (legacyMode.value ? refreshLegacy() : refreshOidc())
            .catch((error) => {
                // A network failure is transient: keep the session and let the caller retry.
                if (error instanceof AuthRejectedError) endSession(endMessage(error));
                throw error;
            })
            .finally(() => {
                refreshing = null;
            });
        return refreshing;
    }

    /** Resumes a session from the stored refresh token. Returns whether one is active. */
    async function restore(): Promise<boolean> {
        if (!loadGrant()) {
            const old = loadLegacy();
            if (!old || old.refreshExpiresAt <= Date.now()) {
                clear();
                return false;
            }
            legacyMode.value = true;
        }
        try {
            await refresh();
        } catch {
            return false;
        }
        return isAuthenticated.value;
    }

    /** Sends the browser to Legacy Auth to sign in. Throws AuthError when it can't be reached. */
    async function signIn(returnTo = '/', withCalendar = true): Promise<void> {
        signInError.value = null;
        redirectTo(await oidc.signInUrl(returnTo, withCalendar));
    }

    /**
     * Completes a sign-in from the OP's redirect. Returns the path to continue at, or null when
     * the browser is being sent back to the OP.
     */
    async function completeSignIn(callbackUrl: URL): Promise<string | null> {
        try {
            const result = await oidc.finishSignIn(callbackUrl);
            // Not clear(): removing the grant key would sign out the other tabs.
            storage.remove(LEGACY_KEY);
            legacyMode.value = false;
            calendar.value = null;
            calendarRefused.value = false;
            saveGrant({ refreshToken: result.refreshToken, idToken: result.idToken, calendar: result.calendar });
            grantHasCalendar.value = result.calendar;
            adoptTracker(result);
            return result.returnTo;
        } catch (error) {
            if (error instanceof SignInDeniedError && error.calendarRequested) {
                // Possibly only the calendar was refused. Ask again for the tracker alone; the user
                // is already signed in at the OP, so this is a redirect, not a second sign-in.
                try {
                    await signIn(error.returnTo, false);
                    return null;
                } catch {
                    // fall through to the message
                }
            }
            endSession(error instanceof AuthError ? error.message : 'Sign-in failed. Please try again.');
            return '/login';
        }
    }

    /** Signs out here and, for an OP session, at Legacy Auth (which ends it for every app). */
    async function logout(): Promise<void> {
        const grant = loadGrant();
        const old = loadLegacy();
        endSession();
        if (old) await legacy.logout(old.refreshToken);
        if (grant) {
            try {
                redirectTo(await oidc.signOutUrl(grant.idToken));
            } catch {
                // Offline: the local session is gone, the OP one ends with its own timeout.
            }
        }
    }

    /** The session ended elsewhere (lost access, or signed out through the OP). */
    function expire(message: string | null = null) {
        endSession(message);
    }

    /** A valid tracker access token, refreshing first when it is about to expire. Null when signed out. */
    async function getAccessToken(): Promise<string | null> {
        if (tracker.value && !isFresh(tracker.value)) {
            try {
                await refresh();
            } catch {
                // Rejected: the session is already cleared. Transient: use what we have.
            }
        }
        return tracker.value?.accessToken ?? null;
    }

    /**
     * A token Legacy Calendar accepts (`aud: calendar`), from the same grant. Null when the account
     * has no calendar. Throws AuthError when the sign-in server can't be reached.
     */
    async function getCalendarToken(): Promise<string | null> {
        if (!hasCalendarScope.value) return null;
        // Old password-login tokens are addressed to both apps.
        if (legacyMode.value) return getAccessToken();
        if (isFresh(calendar.value)) return calendar.value.accessToken;
        calendarRefreshing ??= withRefreshLock(async () => {
            const stored = loadGrant();
            if (!stored) return null;
            try {
                const next = await oidc.refreshGrant(stored.refreshToken, CALENDAR_RESOURCE);
                saveGrant({ ...stored, refreshToken: next.refreshToken });
                calendar.value = { accessToken: next.accessToken, expiresAt: next.expiresAt };
                return next.accessToken;
            } catch (error) {
                if (!(error instanceof AuthRejectedError)) throw error;
                calendar.value = null;
                calendarRefused.value = true;
                return null;
            }
        }).finally(() => {
            calendarRefreshing = null;
        });
        return calendarRefreshing;
    }

    // Another tab signed out (or the grant was cleared): follow it.
    if (typeof window !== 'undefined') {
        window.addEventListener('storage', (event) => {
            if (event.storageArea !== localStorage) return;
            if ((event.key === STORAGE_KEY || event.key === null) && event.newValue === null && !legacyMode.value) {
                tracker.value = null;
                calendar.value = null;
            }
        });
    }

    return {
        accessToken,
        isAuthenticated,
        username,
        hasCalendarScope,
        signInError,
        restore,
        signIn,
        completeSignIn,
        logout,
        expire,
        refresh,
        getAccessToken,
        getCalendarToken
    };
});
