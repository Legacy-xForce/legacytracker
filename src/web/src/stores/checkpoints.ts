import { defineStore } from 'pinia';
import { ref } from 'vue';
import { trackerJson } from '../api/tracker';
import { haversine } from '../lib/replay';

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

/**
 * The saved place a point is inside, if any. Overlaps go to the smallest radius (the most specific
 * place); ties go to the nearest centre. Mirrors the server and the phone app.
 */
export function resolveCheckpoint(latitude: number, longitude: number, checkpoints: Checkpoint[]): Checkpoint | null {
    let best: Checkpoint | null = null;
    let bestDistance = Infinity;
    for (const checkpoint of checkpoints) {
        const meters = haversine(latitude, longitude, checkpoint.latitude, checkpoint.longitude);
        if (meters > checkpoint.radius) continue;
        if (!best || checkpoint.radius < best.radius || (checkpoint.radius === best.radius && meters < bestDistance)) {
            best = checkpoint;
            bestDistance = meters;
        }
    }
    return best;
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

    function resolve(latitude: number, longitude: number): Checkpoint | null {
        return resolveCheckpoint(latitude, longitude, checkpoints.value);
    }

    return { checkpoints, error, load, resolve };
});
