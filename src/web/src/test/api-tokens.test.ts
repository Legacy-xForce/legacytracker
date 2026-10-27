import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createApiToken, listApiTokens, parseApiToken, updateApiTokenAllowedIps } from '../api/apiTokens';
import ApiTokensDialog from '../components/account/ApiTokensDialog.vue';
import { toasts } from '../lib/toast';
import { openApiDocument } from '../lib/openapi';
import { router } from '../router';
import { fakeJwt, jsonResponse, tokenResponse, startSession } from './helpers';

const summary = {
    id: '0e7a3c3e-2f7b-4f63-9c55-0bb0a4f3c1d2',
    name: 'Home Assistant',
    scope: 'read',
    token_hint: 'legacy-tracker-01a1…1289',
    allowed_ips: [],
    created_at: '2026-10-20T08:00:00.000Z',
    last_used_at: null,
    rotated_at: null
};
const secret = 'legacy-tracker-01a15968-64aa-707d-8904-a6a408611289';
/** The address the token endpoints answer from, so the dialog can offer it. */
const seenFrom = '198.51.100.7';

let fetchMock: ReturnType<typeof vi.fn>;

/** Requests to the token endpoints (not the sign-in) made with `method`. */
function calls(method: string): { url: URL; body: unknown }[] {
    return fetchMock.mock.calls
        .map(([url, init]) => ({ url: new URL(String(url)), init: init as RequestInit | undefined }))
        .filter(({ url, init }) => url.pathname.startsWith('/api/v1/api-tokens') && (init?.method ?? 'GET') === method)
        .map(({ url, init }) => ({ url, body: init?.body ? JSON.parse(String(init.body)) : undefined }));
}

async function signIn() {
    fetchMock.mockResolvedValueOnce(
        jsonResponse(tokenResponse(fakeJwt({ sub: 'u', username: 'ada', scopes: { tracker: true } })))
    );
    await startSession();
}

beforeEach(() => {
    localStorage.clear();
    toasts.value = [];
    setActivePinia(createPinia());
    fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
    vi.unstubAllGlobals();
    document.body.innerHTML = '';
});

describe('API token client', () => {
    beforeEach(signIn);

    it('parses summaries and skips malformed ones', () => {
        expect(parseApiToken(summary)).toEqual({
            id: summary.id,
            name: 'Home Assistant',
            scope: 'read',
            hint: 'legacy-tracker-01a1…1289',
            allowedIps: [],
            createdAt: Date.parse(summary.created_at),
            lastUsedAt: null,
            rotatedAt: null
        });
        expect(parseApiToken({ ...summary, allowed_ips: ['203.0.113.0/24', 42] })).toMatchObject({
            allowedIps: ['203.0.113.0/24']
        });
        expect(parseApiToken({ ...summary, scope: 'admin' })).toBeNull();
        expect(parseApiToken(null)).toBeNull();
    });

    it('lists with the session token, and reports the address it answered', async () => {
        fetchMock.mockResolvedValueOnce(jsonResponse({ tokens: [summary, { id: 1 }], your_ip: seenFrom }));
        const { tokens, yourIp } = await listApiTokens();
        expect(tokens.map((t) => t.id)).toEqual([summary.id]);
        expect(yourIp).toBe(seenFrom);
        const [, init] = fetchMock.mock.calls.at(-1)!;
        expect((init as RequestInit).headers).toMatchObject({ authorization: expect.stringMatching(/^Bearer /) });
    });

    it('replaces the allowed addresses with a patch', async () => {
        fetchMock.mockResolvedValueOnce(jsonResponse({ ...summary, allowed_ips: ['203.0.113.7'] }));
        const token = await updateApiTokenAllowedIps(summary.id, ['203.0.113.7']);
        expect(token.allowedIps).toEqual(['203.0.113.7']);
        const { url, body } = calls('PATCH')[0];
        expect(url.pathname).toBe(`/api/v1/api-tokens/${summary.id}`);
        expect(body).toEqual({ allowed_ips: ['203.0.113.7'] });
    });

    it("surfaces the server's message when creation is refused", async () => {
        fetchMock.mockResolvedValueOnce(
            jsonResponse({ error: 'You already have 25 API tokens. Delete one first.' }, 400)
        );
        await expect(createApiToken('x', 'read')).rejects.toThrow('You already have 25 API tokens');
    });
});

describe('API tokens dialog', () => {
    beforeEach(signIn);

    async function open() {
        const wrapper = mount(ApiTokensDialog, { attachTo: document.body, global: { stubs: { RouterLink: true } } });
        await flushPromises();
        return wrapper;
    }

    /** Opens the settings panel under a row, where rotate, delete and the allowlist live. */
    async function openEdit(name = 'Home Assistant') {
        (document.body.querySelector(`[aria-label="Edit ${name}"]`) as HTMLButtonElement).click();
        await flushPromises();
    }

    function click(selector: string) {
        (document.body.querySelector(selector) as HTMLElement).click();
    }

    it('creates a token and shows its value once', async () => {
        fetchMock.mockImplementation(async (_url: string, init?: RequestInit) =>
            init?.method === 'POST'
                ? jsonResponse({ ...summary, scope: 'write', name: 'Uploader', token: secret }, 201)
                : jsonResponse({ tokens: [] })
        );
        await open();
        expect(document.body.textContent).toContain('No tokens yet.');

        const input = document.body.querySelector('input') as HTMLInputElement;
        input.value = 'Uploader';
        input.dispatchEvent(new Event('input'));
        (document.body.querySelector('[role=radio]:nth-child(2)') as HTMLButtonElement).click();
        document.body.querySelector('form')!.dispatchEvent(new Event('submit'));
        await flushPromises();

        expect(calls('POST')[0].body).toEqual({ name: 'Uploader', scope: 'write' });
        expect(document.body.querySelector('[data-token]')?.textContent).toBe(secret);
        expect(document.body.querySelectorAll('[data-token-row]')).toHaveLength(1);

        (
            Array.from(document.body.querySelectorAll('button')).find(
                (b) => b.textContent?.trim() === 'Done'
            ) as HTMLButtonElement
        ).click();
        await flushPromises();
        expect(document.body.querySelector('[data-token]')).toBeNull();
        expect(document.body.textContent).not.toContain(secret);
    });

    it('rotates after confirming and reveals the new value', async () => {
        const rotated = `${secret.slice(0, -4)}beef`;
        fetchMock.mockImplementation(async (url: string, init?: RequestInit) =>
            init?.method === 'POST' && String(url).endsWith('/rotate')
                ? jsonResponse({ ...summary, rotated_at: '2026-10-20T09:00:00.000Z', token: rotated })
                : jsonResponse({ tokens: [summary] })
        );
        await open();
        await openEdit();
        (document.body.querySelector('[aria-label="Rotate Home Assistant"]') as HTMLButtonElement).click();
        await flushPromises();
        expect(document.body.textContent).toContain('Rotate token?');
        expect(calls('POST')).toHaveLength(0);

        (document.body.querySelector('[data-confirm]') as HTMLButtonElement).click();
        await flushPromises();
        expect(calls('POST')[0].url.pathname).toBe(`/api/v1/api-tokens/${summary.id}/rotate`);
        expect(document.body.querySelector('[data-token]')?.textContent).toBe(rotated);
    });

    it('deletes after confirming', async () => {
        fetchMock.mockImplementation(async (_url: string, init?: RequestInit) =>
            init?.method === 'DELETE' ? jsonResponse({ deleted: true }) : jsonResponse({ tokens: [summary] })
        );
        await open();
        await openEdit();
        (document.body.querySelector('[aria-label="Delete Home Assistant"]') as HTMLButtonElement).click();
        await flushPromises();
        (document.body.querySelector('[data-confirm]') as HTMLButtonElement).click();
        await flushPromises();
        expect(calls('DELETE')[0].url.pathname).toBe(`/api/v1/api-tokens/${summary.id}`);
        expect(document.body.querySelectorAll('[data-token-row]')).toHaveLength(0);
        expect(document.body.textContent).toContain('No tokens yet.');
    });

    it('keeps rotate and delete out of reach until a row is edited', async () => {
        fetchMock.mockImplementation(async () => jsonResponse({ tokens: [summary] }));
        await open();
        expect(document.body.querySelector('[aria-label="Rotate Home Assistant"]')).toBeNull();
        expect(document.body.querySelector('[aria-label="Delete Home Assistant"]')).toBeNull();
        expect(document.body.querySelector('[data-save-allowlist]')).toBeNull();
    });

    it('saves an address allowlist and shows it on the row', async () => {
        fetchMock.mockImplementation(async (_url: string, init?: RequestInit) =>
            init?.method === 'PATCH'
                ? jsonResponse({ ...summary, allowed_ips: ['203.0.113.0/24'] })
                : jsonResponse({ tokens: [summary], your_ip: seenFrom })
        );
        await open();
        expect(document.body.querySelector('[data-allowed-ips]')).toBeNull();

        await openEdit();
        // The address the API is answering from is offered before it is listed.
        expect(document.body.querySelector('[data-add-your-ip]')?.textContent).toContain(seenFrom);
        const field = document.body.querySelector('[data-allow-entry]') as HTMLInputElement;
        field.value = ' 203.0.113.0/24 ';
        field.dispatchEvent(new Event('input'));
        click('[data-add-entry]');
        await flushPromises();
        // What was typed becomes a removable chip before anything is saved.
        expect(document.body.querySelector('[aria-label="Remove 203.0.113.0/24"]')).not.toBeNull();
        click('[data-save-allowlist]');
        await flushPromises();

        expect(calls('PATCH')[0].url.pathname).toBe(`/api/v1/api-tokens/${summary.id}`);
        expect(calls('PATCH')[0].body).toEqual({ allowed_ips: ['203.0.113.0/24'] });
        expect(document.body.querySelector('[data-allowed-ips]')?.textContent).toContain('203.0.113.0/24');
        expect(document.body.querySelector('[data-save-allowlist]')).toBeNull();
        expect(toasts.value[0]?.message).toContain('1 address');
    });

    it('adds the address the API is answering from in one click', async () => {
        fetchMock.mockImplementation(async (_url: string, init?: RequestInit) =>
            init?.method === 'PATCH'
                ? jsonResponse({ ...summary, allowed_ips: [seenFrom] })
                : jsonResponse({ tokens: [summary], your_ip: seenFrom })
        );
        await open();
        await openEdit();
        click('[data-add-your-ip]');
        await flushPromises();
        click('[data-save-allowlist]');
        await flushPromises();
        expect(calls('PATCH')[0].body).toEqual({ allowed_ips: [seenFrom] });
    });

    it('lifts the restriction once every address is removed', async () => {
        fetchMock.mockImplementation(async (_url: string, init?: RequestInit) =>
            init?.method === 'PATCH'
                ? jsonResponse({ ...summary, allowed_ips: [] })
                : jsonResponse({ tokens: [{ ...summary, allowed_ips: ['203.0.113.7'] }] })
        );
        await open();
        expect(document.body.querySelector('[data-allowed-ips]')?.textContent).toContain('203.0.113.7');
        await openEdit();
        click('[aria-label="Remove 203.0.113.7"]');
        await flushPromises();
        click('[data-save-allowlist]');
        await flushPromises();
        expect(calls('PATCH')[0].body).toEqual({ allowed_ips: [] });
        expect(document.body.querySelector('[data-allowed-ips]')).toBeNull();
        expect(toasts.value[0]?.message).toContain('any address');
    });

    it("surfaces the server's refusal of a bad entry and keeps the draft", async () => {
        fetchMock.mockImplementation(async (_url: string, init?: RequestInit) =>
            init?.method === 'PATCH'
                ? jsonResponse({ error: '`203.0.113.999` is not an IP address or CIDR prefix' }, 400)
                : jsonResponse({ tokens: [summary] })
        );
        await open();
        await openEdit();
        const field = document.body.querySelector('[data-allow-entry]') as HTMLInputElement;
        field.value = '203.0.113.999';
        field.dispatchEvent(new Event('input'));
        click('[data-add-entry]');
        click('[data-save-allowlist]');
        await flushPromises();
        expect(toasts.value[0]?.message).toContain('is not an IP address');
        expect(document.body.querySelector('[data-save-allowlist]')).not.toBeNull();
    });
});

describe('API docs', () => {
    it('are reachable without signing in', async () => {
        await router.push('/docs');
        expect(router.currentRoute.value.name).toBe('docs');
    });

    it('publish an OpenAPI document for the API', () => {
        expect(openApiDocument.openapi).toBe('3.1.0');
        expect(openApiDocument.info.title).toBe('Legacy Tracker API');
        expect(openApiDocument.paths['/api/v1/location'].post.operationId).toBe('post-location');
        expect(openApiDocument.paths['/api/v1/history'].get.operationId).toBe('get-history');
        expect(openApiDocument.paths['/api/v1/api-tokens/{id}/rotate'].post.operationId).toBe('rotate-token');
        expect(openApiDocument.paths['/api/v1/api-tokens/{id}'].patch.operationId).toBe('update-token');
        expect(openApiDocument.paths['/api/v1/stream'].get.operationId).toBe('stream');
    });

    it('separates token endpoints from session-only ones', () => {
        expect(openApiDocument.paths['/api/v1/profile'].get.security).toEqual([{ apiToken: [] }, { bearerAuth: [] }]);
        expect(openApiDocument.paths['/api/v1/api-tokens'].get.security).toEqual([{ bearerAuth: [] }]);
        expect(openApiDocument.paths['/api/v1/api-tokens/{id}'].patch.security).toEqual([{ bearerAuth: [] }]);
        expect(openApiDocument.paths['/api/v1/app/android/latest'].get.security).toEqual([]);
    });

    it('documents both credential schemes', () => {
        expect(openApiDocument.components.securitySchemes.apiToken).toMatchObject({
            type: 'apiKey',
            in: 'header',
            name: 'X-API-Token'
        });
        expect(openApiDocument.components.securitySchemes.bearerAuth).toMatchObject({
            type: 'http',
            scheme: 'bearer'
        });
    });
});
