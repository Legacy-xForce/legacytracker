import { storage } from './storage';

const CACHE_KEY = 'legacytracker.eventGeocode.v1';
const SEARCH_URL = 'https://nominatim.openstreetmap.org/search';

export type Point = [number, number];

export function normalizeLocation(location: string): string {
    return location.trim().toLowerCase().replace(/\s+/g, ' ');
}

/**
 * Turns an event's free-text location into a map point, remembering every answer (including "no
 * such place") so Nominatim is asked about a given text once. Lookups run one at a time, spaced out
 * to respect its usage policy. A failed lookup is not remembered, so it is retried later.
 */
export class EventGeocoder {
    private readonly cache = new Map<string, Point | null>();
    private queue: Promise<unknown> = Promise.resolve();
    private lastRequest = 0;

    constructor(
        private readonly options: {
            fetch?: typeof fetch;
            spacingMs?: number;
            sleep?: (ms: number) => Promise<void>;
            now?: () => number;
        } = {}
    ) {
        try {
            const stored = JSON.parse(storage.get(CACHE_KEY) ?? '{}') as Record<string, unknown>;
            for (const [key, value] of Object.entries(stored)) {
                this.cache.set(
                    key,
                    Array.isArray(value) && value.length === 2 ? [Number(value[0]), Number(value[1])] : null
                );
            }
        } catch {
            this.cache.clear();
        }
    }

    /** The answer if we already have one; `known` tells "not found" apart from "never asked". */
    peek(location: string): { known: boolean; point: Point | null } {
        const key = normalizeLocation(location);
        return { known: this.cache.has(key), point: this.cache.get(key) ?? null };
    }

    /** Null when the place can't be pinpointed or the lookup failed. */
    resolve(location: string): Promise<Point | null> {
        const result = this.queue.then(() => this.lookup(location)).catch(() => null);
        this.queue = result;
        return result;
    }

    private async lookup(location: string): Promise<Point | null> {
        const key = normalizeLocation(location);
        if (this.cache.has(key)) return this.cache.get(key) ?? null;

        const now = this.options.now ?? Date.now;
        const wait = (this.options.spacingMs ?? 1100) - (now() - this.lastRequest);
        if (this.lastRequest > 0 && wait > 0) {
            await (this.options.sleep ?? ((ms) => new Promise<void>((r) => setTimeout(r, ms))))(wait);
        }
        this.lastRequest = now();

        const query = new URLSearchParams({ format: 'jsonv2', q: location, limit: '1' });
        const response = await (this.options.fetch ?? fetch)(`${SEARCH_URL}?${query}`, {
            headers: { accept: 'application/json' }
        });
        if (!response.ok) throw new Error(`Geocoder error (${response.status}).`);
        const results = (await response.json()) as { lat?: string; lon?: string }[];
        const first = results[0];
        const point: Point | null =
            first && Number.isFinite(Number(first.lat)) && Number.isFinite(Number(first.lon))
                ? [Number(first.lat), Number(first.lon)]
                : null;
        this.cache.set(key, point);
        storage.set(CACHE_KEY, JSON.stringify(Object.fromEntries(this.cache)));
        return point;
    }
}
