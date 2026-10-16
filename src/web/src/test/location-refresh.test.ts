import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { nextTick } from 'vue';
import PersonDetail from '../components/people/PersonDetail.vue';
import ToastHost from '../components/ui/ToastHost.vue';
import type { Peer } from '../lib/peers';
import { toasts } from '../lib/toast';
import { UNREACHABLE_MESSAGE, usePeersStore } from '../stores/peers';
import { useSessionStore } from '../stores/session';
import { fakeJwt, jsonResponse, tokenResponse } from './helpers';

let fetchMock: ReturnType<typeof vi.fn>;

function refreshCalls(): URL[] {
    return fetchMock.mock.calls
        .filter(([, init]) => (init as RequestInit | undefined)?.method === 'POST')
        .map(([url]) => new URL(String(url)));
}

beforeEach(async () => {
    localStorage.clear();
    toasts.value = [];
    setActivePinia(createPinia());
    fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    fetchMock.mockResolvedValueOnce(
        jsonResponse(tokenResponse(fakeJwt({ sub: 'u', username: 'ada', scopes: { tracker: true } })))
    );
    await useSessionStore().login('ada', 'pw');
    fetchMock.mockReset();
});

afterEach(() => vi.unstubAllGlobals());

describe('refreshLocation', () => {
    it('posts the request for that user and applies the fresh entry', async () => {
        const peers = usePeersStore();
        fetchMock.mockResolvedValue(
            jsonResponse({
                user_id: 'bob',
                username: 'Bob',
                sharing: true,
                latitude: 45.1,
                longitude: 9.2,
                speed: 0,
                heading: null,
                recorded_at: '2026-10-16T10:00:00.000Z',
                last_seen_at: '2026-10-16T10:00:03.000Z'
            })
        );
        await peers.refreshLocation('bob', 'Bob');
        const [call] = refreshCalls();
        expect(call.pathname).toBe('/api/v1/users/bob/location-refresh');
        expect(peers.peers.get('bob')?.latitude).toBe(45.1);
    });

    it.each([504, 409])('explains an unreachable device (HTTP %i)', async (status) => {
        fetchMock.mockResolvedValue(jsonResponse({ error: 'device_unreachable' }, status));
        await expect(usePeersStore().refreshLocation('bob', 'Bob')).rejects.toThrow(UNREACHABLE_MESSAGE);
    });

    it('says so when the person stopped sharing with you', async () => {
        fetchMock.mockResolvedValue(jsonResponse({ error: 'not_sharing' }, 403));
        await expect(usePeersStore().refreshLocation('bob', 'Bob')).rejects.toThrow("Bob isn't sharing");
    });

    it('reports an unreachable tracker', async () => {
        fetchMock.mockRejectedValue(new TypeError('network'));
        await expect(usePeersStore().refreshLocation('bob', 'Bob')).rejects.toThrow('Unable to reach the tracker.');
    });
});

describe('the refresh button', () => {
    const peer: Peer = {
        id: 'bob',
        name: 'Bob',
        sharing: true,
        latitude: 45,
        longitude: 9,
        speed: 0,
        heading: null,
        recordedAt: Date.now(),
        lastSeenAt: Date.now(),
        hereSince: null,
        batteryLevel: 80,
        isCharging: false,
        trackingIssues: []
    };

    function open(overrides: Partial<Peer> = {}) {
        return mount(
            {
                components: { PersonDetail, ToastHost },
                template: '<PersonDetail :peer="peer" :self="false" :now="now" /><ToastHost />',
                data: () => ({ peer: { ...peer, ...overrides }, now: Date.now() })
            },
            { global: { stubs: { PlaceLabel: true } } }
        );
    }

    it('spins while waiting, then goes idle after the phone answers', async () => {
        let answer!: (response: Response) => void;
        fetchMock.mockImplementation(
            (url: string) =>
                new Promise<Response>((resolve) => {
                    if (String(url).includes('location-refresh')) answer = resolve;
                    else resolve(jsonResponse({ sessions: [] }));
                })
        );
        const wrapper = open();
        const button = wrapper.get('button[aria-label^="Force location update"]');
        expect(button.find('.animate-spin').exists()).toBe(false);

        await button.trigger('click');
        await vi.waitFor(() => expect(typeof answer).toBe('function'));
        await nextTick();
        expect(button.find('.animate-spin').exists()).toBe(true);
        expect(button.attributes('disabled')).toBeDefined();

        answer(jsonResponse({ user_id: 'bob', username: 'Bob', sharing: true }));
        await vi.waitFor(() => expect(button.find('.animate-spin').exists()).toBe(false));
        expect(toasts.value).toHaveLength(0);
    });

    it('stops spinning and shows the error as a toast when the phone is unreachable', async () => {
        fetchMock.mockImplementation(async (url: string) =>
            String(url).includes('location-refresh')
                ? jsonResponse({ error: 'device_unreachable' }, 504)
                : jsonResponse({ sessions: [] })
        );
        const wrapper = open();
        const button = wrapper.get('button[aria-label^="Force location update"]');
        await button.trigger('click');
        await vi.waitFor(() => expect(toasts.value).toHaveLength(1));
        expect(toasts.value[0].message).toBe(UNREACHABLE_MESSAGE);
        expect(button.find('.animate-spin').exists()).toBe(false);
        expect(wrapper.text()).toContain(UNREACHABLE_MESSAGE);
    });

    it('is not offered for someone who hides from you', () => {
        const wrapper = open({ sharing: false });
        expect(wrapper.find('button[aria-label^="Force location update"]').exists()).toBe(false);
    });
});
