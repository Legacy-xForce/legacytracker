import { defineStore } from 'pinia';
import { ref } from 'vue';
import { ApiError, trackerFetch, trackerJson } from '../api/tracker';
import { haversine } from '../lib/replay';

export interface Checkpoint {
    id: string;
    name: string;
    latitude: number;
    longitude: number;
    /** Metres. */
    radius: number;
    /** Whether the caller created it or is an admin; the server decides. */
    canEdit: boolean;
}

export const MIN_RADIUS_M = 10;
export const MAX_RADIUS_M = 250;
export const MAX_NAME_LENGTH = 60;

/** What the editor submits. */
export interface CheckpointInput {
    name: string;
    latitude: number;
    longitude: number;
    radius: number;
}

/** A save the server refused, with a message safe to show. `nameTaken` marks the 409. */
export class CheckpointError extends Error {
    constructor(
        message: string,
        readonly nameTaken = false
    ) {
        super(message);
    }
}

export function parseCheckpoints(body: unknown): Checkpoint[] {
    const list = (body as { checkpoints?: unknown } | null)?.checkpoints;
    if (!Array.isArray(list)) return [];
    const parsed: Checkpoint[] = [];
    for (const raw of list as Record<string, unknown>[]) {
        const { id, name, latitude, longitude, radius_m: radius, can_edit: canEdit } = raw;
        if (
            (typeof id !== 'string' && typeof id !== 'number') ||
            typeof name !== 'string' ||
            typeof latitude !== 'number' ||
            typeof longitude !== 'number' ||
            typeof radius !== 'number'
        ) {
            continue;
        }
        parsed.push({ id: String(id), name, latitude, longitude, radius, canEdit: canEdit === true });
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

function body(input: CheckpointInput): string {
    return JSON.stringify({
        name: input.name,
        latitude: input.latitude,
        longitude: input.longitude,
        radius_m: input.radius
    });
}

async function refused(response: Response): Promise<CheckpointError> {
    switch (response.status) {
        case 409:
            return new CheckpointError('A checkpoint with that name already exists.', true);
        case 403:
            return new CheckpointError("You can't change this checkpoint.");
        case 404:
            return new CheckpointError('This checkpoint no longer exists.');
        case 400: {
            const detail = (await response.json().catch(() => null)) as { error?: unknown } | null;
            return new CheckpointError(typeof detail?.error === 'string' ? detail.error : 'Invalid checkpoint.');
        }
        default:
            return new CheckpointError(`Something went wrong (${response.status}). Try again.`);
    }
}

/** Sends a change; an unreachable tracker and a refusal both come back as a `CheckpointError`. */
async function change(path: string, method: string, input?: CheckpointInput): Promise<void> {
    let response: Response;
    try {
        response = await trackerFetch(path, {
            method,
            ...(input ? { headers: { 'content-type': 'application/json' }, body: body(input) } : {})
        });
    } catch (error) {
        if (error instanceof ApiError && error.status === 0) {
            throw new CheckpointError('Unable to reach the server. Check your connection and try again.');
        }
        throw error;
    }
    if (!response.ok) throw await refused(response);
}

/** The saved places everyone shares. Anyone can see them; only a creator or an admin changes one. */
export const useCheckpointsStore = defineStore('checkpoints', () => {
    const checkpoints = ref<Checkpoint[]>([]);
    const error = ref(false);
    const loaded = ref(false);

    async function load() {
        try {
            checkpoints.value = parseCheckpoints(await trackerJson('/api/v1/checkpoints'));
            error.value = false;
        } catch {
            error.value = true;
        } finally {
            loaded.value = true;
        }
    }

    async function create(input: CheckpointInput) {
        await change('/api/v1/checkpoints', 'POST', input);
        await load();
    }

    async function update(id: string, input: CheckpointInput) {
        await change(`/api/v1/checkpoints/${encodeURIComponent(id)}`, 'PATCH', input);
        await load();
    }

    async function remove(id: string) {
        await change(`/api/v1/checkpoints/${encodeURIComponent(id)}`, 'DELETE');
        checkpoints.value = checkpoints.value.filter((checkpoint) => checkpoint.id !== id);
    }

    function resolve(latitude: number, longitude: number): Checkpoint | null {
        return resolveCheckpoint(latitude, longitude, checkpoints.value);
    }

    return { checkpoints, error, loaded, load, create, update, remove, resolve };
});
