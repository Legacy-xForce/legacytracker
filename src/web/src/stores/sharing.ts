import { defineStore } from 'pinia';
import { ref } from 'vue';
import { trackerFetch } from '../api/tracker';

function parseHidden(body: unknown): Set<string> {
    const list = (body as { hidden_from?: unknown } | null)?.hidden_from;
    return new Set(Array.isArray(list) ? list.filter((id): id is string => typeof id === 'string') : []);
}

async function serverMessage(response: Response, fallback: string): Promise<string> {
    const body = (await response.json().catch(() => null)) as { error?: unknown } | null;
    return typeof body?.error === 'string' ? body.error : fallback;
}

/**
 * Whom the signed-in user hides their location from. Sharing is on by default, so the server only
 * keeps the exceptions. It is an account setting, so it applies to their phone too.
 */
export const useSharingStore = defineStore('sharing', () => {
    const hiddenFrom = ref(new Set<string>());
    const loaded = ref(false);

    async function load() {
        try {
            const response = await trackerFetch('/api/v1/sharing');
            if (!response.ok) return;
            hiddenFrom.value = parseHidden(await response.json());
            loaded.value = true;
        } catch {
            // The toggle stays unavailable.
        }
    }

    function isSharingWith(userId: string): boolean {
        return !hiddenFrom.value.has(userId);
    }

    /** Throws an Error with a message fit to show when the server refuses. */
    async function setSharing(userId: string, enabled: boolean): Promise<void> {
        const response = await trackerFetch(`/api/v1/sharing/${encodeURIComponent(userId)}`, {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ enabled })
        });
        if (!response.ok) throw new Error(await serverMessage(response, 'Could not change sharing.'));
        hiddenFrom.value = parseHidden(await response.json());
    }

    function reset() {
        hiddenFrom.value = new Set();
        loaded.value = false;
    }

    return { hiddenFrom, loaded, load, isSharingWith, setSharing, reset };
});
