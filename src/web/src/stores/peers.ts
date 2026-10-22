import { defineStore } from 'pinia';
import { computed, ref, shallowRef } from 'vue';
import { ApiError, requestStreamTicket, trackerFetch } from '../api/tracker';
import { StreamClient, type StreamStatus } from '../api/stream';
import { applyMessage, type Peer } from '../lib/peers';
import { parseViewers, type Viewer } from '../lib/viewers';
import { useSessionStore } from './session';

export const UNREACHABLE_MESSAGE =
    'Unable to reach device for location update. The device may be offline or in battery saver mode.';

export const usePeersStore = defineStore('peers', () => {
    const peers = shallowRef<Map<string, Peer>>(new Map());
    const status = ref<StreamStatus>('closed');
    // Until the first snapshot arrives, an empty roster means "loading", not "nobody".
    const loaded = ref(false);
    // Who has the map open right now, us included. Kept through a reconnect; the new connection
    // sends a fresh list.
    const viewers = shallowRef<Viewer[]>([]);
    let client: StreamClient | null = null;

    const list = computed(() => [...peers.value.values()]);

    function receive(message: unknown) {
        if (typeof message === 'object' && message !== null && (message as { type?: unknown }).type === 'signed_out') {
            // The session ended at Legacy Auth (signed out elsewhere, or access removed).
            useSessionStore().expire();
            return;
        }
        const announced = parseViewers(message);
        if (announced) {
            viewers.value = announced;
            return;
        }
        const next = new Map(peers.value);
        if (applyMessage(next, message)) peers.value = next;
        if (typeof message === 'object' && message !== null && (message as { type?: unknown }).type === 'snapshot') {
            loaded.value = true;
        }
    }

    function start() {
        if (client) return;
        client = new StreamClient({
            getTicket: requestStreamTicket,
            onMessage: receive,
            onStatus: (next) => (status.value = next),
            // Access errors already ended the session; nothing to retry.
            isFatal: (error) => error instanceof ApiError && (error.status === 401 || error.status === 403)
        });
        client.start();
    }

    function stop() {
        client?.stop();
        client = null;
        peers.value = new Map();
        viewers.value = [];
        loaded.value = false;
    }

    /** Whether the map is in the foreground: while any map is, phones stream in realtime. */
    function setMapActive(active: boolean) {
        client?.setMapActive(active);
    }

    /** A fresh connection also brings a fresh snapshot, so this is how a stale view recovers. */
    function reconnect() {
        client?.reconnect();
    }

    /**
     * Asks `userId`'s phone for a fresh position and resolves once it has reported in. Throws an
     * Error with a message fit to show when the phone can't be reached.
     */
    async function refreshLocation(userId: string, name: string): Promise<void> {
        let response: Response;
        try {
            response = await trackerFetch(`/api/v1/users/${encodeURIComponent(userId)}/location-refresh`, {
                method: 'POST'
            });
        } catch (error) {
            if (error instanceof ApiError && error.status === 0) throw new Error(error.message);
            throw error;
        }
        if (response.ok) {
            // The stream normally delivers this first; applying it covers a stream that is down.
            receive(await response.json().catch(() => null));
            return;
        }
        const body = (await response.json().catch(() => null)) as { error?: unknown } | null;
        if (body?.error === 'not_sharing') throw new Error(`${name} isn't sharing their location with you.`);
        throw new Error(UNREACHABLE_MESSAGE);
    }

    return { peers, list, status, loaded, viewers, start, stop, setMapActive, reconnect, refreshLocation };
});
