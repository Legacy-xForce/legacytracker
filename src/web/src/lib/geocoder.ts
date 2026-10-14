import { storage } from './storage';
import { nominatim, Throttle, type ThrottleOptions } from './throttle';

const CACHE_KEY = 'legacytracker.eventGeocode.v1';
const SEARCH_URL = 'https://nominatim.openstreetmap.org/search';

export type Point = [number, number];

export function normalizeLocation(location: string): string {
    return location.trim().toLowerCase().replace(/\s+/g, ' ');
}

/**
 * Turns an event's free-text location into a map point, remembering every answer (including "no
 * such place") so Nominatim is asked about a given text once. Lookups share the page's Nominatim
 * throttle. A failed lookup is not remembered, so it is retried later.
 */
export class EventGeocoder {
    private readonly cache = new Map<string, Point | null>();
    private readonly throttle: Throttle;

    constructor(private readonly options: ThrottleOptions & { fetch?: typeof fetch } = {}) {
        const { spacingMs, now, sleep } = options;
        this.throttle = spacingMs !== undefined || now || sleep ? new Throttle({ spacingMs, now, sleep }) : nominatim;
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
        return this.lookup(location).catch(() => null);
    }

    private async lookup(location: string): Promise<Point | null> {
        const key = normalizeLocation(location);
        if (this.cache.has(key)) return this.cache.get(key) ?? null;
        await this.throttle.acquire();
        // Someone else may have asked while this waited its turn.
        if (this.cache.has(key)) return this.cache.get(key) ?? null;

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
