import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createApiToken, listApiTokens, parseApiToken } from '../api/apiTokens';
import ApiTokensDialog from '../components/account/ApiTokensDialog.vue';
import { curlExample, DOC_SECTIONS } from '../lib/apiDocs';
import { router } from '../router';
import { useSessionStore } from '../stores/session';
import { fakeJwt, jsonResponse, tokenResponse } from './helpers';

const summary = {
    id: '0e7a3c3e-2f7b-4f63-9c55-0bb0a4f3c1d2',
    name: 'Home Assistant',
    scope: 'read',
    token_hint: 'legacy-tracker-01a1…1289',
    created_at: '2026-10-20T08:00:00.000Z',
    last_used_at: null,
    rotated_at: null
};
const secret = 'legacy-tracker-01a15968-64aa-707d-8904-a6a408611289';

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
    await useSessionStore().login('ada', 'pw');
}

beforeEach(() => {
    localStorage.clear();
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
            createdAt: Date.parse(summary.created_at),
            lastUsedAt: null,
            rotatedAt: null
        });
        expect(parseApiToken({ ...summary, scope: 'admin' })).toBeNull();
        expect(parseApiToken(null)).toBeNull();
    });

    it('lists with the session token', async () => {
        fetchMock.mockResolvedValueOnce(jsonResponse({ tokens: [summary, { id: 1 }] }));
        const tokens = await listApiTokens();
        expect(tokens.map((t) => t.id)).toEqual([summary.id]);
        const [, init] = fetchMock.mock.calls.at(-1)!;
        expect((init as RequestInit).headers).toMatchObject({ authorization: expect.stringMatching(/^Bearer /) });
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
        (document.body.querySelector('[aria-label="Delete Home Assistant"]') as HTMLButtonElement).click();
        await flushPromises();
        (document.body.querySelector('[data-confirm]') as HTMLButtonElement).click();
        await flushPromises();
        expect(calls('DELETE')[0].url.pathname).toBe(`/api/v1/api-tokens/${summary.id}`);
        expect(document.body.querySelectorAll('[data-token-row]')).toHaveLength(0);
        expect(document.body.textContent).toContain('No tokens yet.');
    });
});

describe('API docs', () => {
    it('are reachable without signing in', async () => {
        await router.push('/docs');
        expect(router.currentRoute.value.name).toBe('docs');
    });

    it('document every endpoint with its access and a request example', () => {
        const endpoints = DOC_SECTIONS.flatMap((section) => section.endpoints);
        expect(new Set(endpoints.map((e) => e.id)).size).toBe(endpoints.length);
        const paths = endpoints.map((e) => `${e.method} ${e.path}`);
        expect(paths).toContain('POST /api/v1/api-tokens/{id}/rotate');
        expect(paths).toContain('POST /api/v1/location');
        expect(endpoints.find((e) => e.id === 'post-location')!.access).toBe('write');
        expect(endpoints.find((e) => e.id === 'get-history')!.access).toBe('read');
        expect(endpoints.find((e) => e.id === 'create-token')!.access).toBe('session');
    });

    it('build curl examples with the right credential', () => {
        const endpoints = Object.fromEntries(DOC_SECTIONS.flatMap((s) => s.endpoints).map((e) => [e.id, e]));
        expect(curlExample(endpoints['get-profile'], 'https://t.example')).toBe(
            'curl "https://t.example/api/v1/profile" \\\n  -H "X-API-Token: $LEGACY_TRACKER_TOKEN"'
        );
        expect(curlExample(endpoints['create-token'], 'https://t.example')).toContain('Authorization: Bearer');
        expect(curlExample(endpoints['android-latest'], 'https://t.example')).not.toContain('-H');
        expect(curlExample(endpoints['create-checkpoint'], 'https://t.example')).toContain('-d \'{"name":"Office"');
    });
});
