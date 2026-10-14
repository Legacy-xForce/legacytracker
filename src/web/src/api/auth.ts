import { config } from '../config';

export interface AuthTokens {
    accessToken: string;
    refreshToken: string;
    /** Epoch ms. */
    expiresAt: number;
    refreshExpiresAt: number;
}

/** A failed auth request, with a message fit to show the user. `status` is 0 when the server was unreachable. */
export class AuthError extends Error {
    constructor(
        message: string,
        readonly status: number
    ) {
        super(message);
    }
}

/** The auth server definitively refused the session, as opposed to a network failure, which is transient. */
export class AuthRejectedError extends AuthError {}

/** An administrator disabled the account in Legacy Auth. Ends the session. */
export class AccountDisabledError extends AuthRejectedError {
    constructor() {
        super('This account has been disabled.', 403);
    }
}

async function post(path: string, body: unknown): Promise<Response> {
    try {
        return await fetch(config.authUrl + path, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(body)
        });
    } catch {
        throw new AuthError('Unable to reach the sign-in server.', 0);
    }
}

async function serverError(response: Response): Promise<string | null> {
    try {
        const body: unknown = await response.json();
        const error = (body as { error?: unknown } | null)?.error;
        return typeof error === 'string' ? error : null;
    } catch {
        return null;
    }
}

function parseTokens(body: Record<string, unknown>, now: number): AuthTokens {
    const { access_token, refresh_token, expires_in, refresh_expires_in } = body;
    if (
        typeof access_token !== 'string' ||
        typeof refresh_token !== 'string' ||
        typeof expires_in !== 'number' ||
        typeof refresh_expires_in !== 'number'
    ) {
        throw new AuthError('Unexpected response from the sign-in server.', 0);
    }
    return {
        accessToken: access_token,
        refreshToken: refresh_token,
        expiresAt: now + expires_in * 1000,
        refreshExpiresAt: now + refresh_expires_in * 1000
    };
}

async function readTokens(response: Response): Promise<AuthTokens> {
    return parseTokens((await response.json()) as Record<string, unknown>, Date.now());
}

export async function login(username: string, password: string): Promise<AuthTokens> {
    const response = await post('/auth/login', { username, password });
    if (response.status === 401) throw new AuthError('Wrong username or password.', 401);
    if (response.status === 403 && (await serverError(response)) === 'Account disabled') {
        throw new AccountDisabledError();
    }
    if (!response.ok) throw new AuthError('Sign-in failed.', response.status);
    return readTokens(response);
}

export async function refresh(refreshToken: string): Promise<AuthTokens> {
    const response = await post('/auth/refresh', { refresh_token: refreshToken });
    if (response.status === 403 && (await serverError(response)) === 'Account disabled') {
        throw new AccountDisabledError();
    }
    if (response.status >= 400 && response.status < 500) {
        throw new AuthRejectedError(`Session rejected (${response.status}).`, response.status);
    }
    if (!response.ok) throw new AuthError('Unable to refresh the session.', response.status);
    return readTokens(response);
}

/** Best effort: the session is gone locally either way. */
export async function logout(refreshToken: string): Promise<void> {
    try {
        await post('/auth/logout', { refresh_token: refreshToken });
    } catch {
        // ignore
    }
}
