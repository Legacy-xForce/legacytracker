import { defineStore } from 'pinia';
import { computed, ref, shallowRef } from 'vue';
import { ApiError, requestStreamTicket } from '../api/tracker';
import { StreamClient, type StreamStatus } from '../api/stream';
import { applyMessage, type Peer } from '../lib/peers';
import { parseViewers, type Viewer } from '../lib/viewers';

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
            // Access errors already flip the session into its denied state; nothing to retry.
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

    return { peers, list, status, loaded, viewers, start, stop, setMapActive, reconnect };
});
