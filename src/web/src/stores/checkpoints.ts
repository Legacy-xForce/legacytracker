import { defineStore } from 'pinia';
import { ref } from 'vue';
import { trackerJson } from '../api/tracker';

export interface Checkpoint {
    id: string;
    name: string;
    latitude: number;
    longitude: number;
    /** Metres. */
    radius: number;
}

export function parseCheckpoints(body: unknown): Checkpoint[] {
    const list = (body as { checkpoints?: unknown } | null)?.checkpoints;
    if (!Array.isArray(list)) return [];
    const parsed: Checkpoint[] = [];
    for (const raw of list as Record<string, unknown>[]) {
        const { id, name, latitude, longitude, radius_m: radius } = raw;
        if (
            (typeof id !== 'string' && typeof id !== 'number') ||
            typeof name !== 'string' ||
            typeof latitude !== 'number' ||
            typeof longitude !== 'number' ||
            typeof radius !== 'number'
        ) {
            continue;
        }
        parsed.push({ id: String(id), name, latitude, longitude, radius });
    }
    return parsed;
}

/** The saved places everyone shares (read-only here; they are edited in the phone app). */
export const useCheckpointsStore = defineStore('checkpoints', () => {
    const checkpoints = ref<Checkpoint[]>([]);
    const error = ref(false);

    async function load() {
        try {
            checkpoints.value = parseCheckpoints(await trackerJson('/api/v1/checkpoints'));
            error.value = false;
        } catch {
            error.value = true;
        }
    }

    return { checkpoints, error, load };
});
