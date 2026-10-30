import { nominatim, type Throttle } from './throttle';

const SEARCH_URL = 'https://nominatim.openstreetmap.org/search';

export interface PlaceResult {
    label: string;
    latitude: number;
    longitude: number;
}

/** Streets and places matching `query`, for aiming the saved-place editor. Throws when the lookup fails. */
export async function searchPlaces(
    query: string,
    options: { fetch?: typeof fetch; throttle?: Throttle } = {}
): Promise<PlaceResult[]> {
    await (options.throttle ?? nominatim).acquire();
    const params = new URLSearchParams({ format: 'jsonv2', q: query, limit: '5' });
    const response = await (options.fetch ?? fetch)(`${SEARCH_URL}?${params}`, {
        headers: { accept: 'application/json' }
    });
    if (!response.ok) throw new Error(`Place search error (${response.status}).`);
    const rows = (await response.json()) as { lat?: string; lon?: string; display_name?: string }[];
    const results: PlaceResult[] = [];
    for (const row of rows) {
        const latitude = Number(row.lat);
        const longitude = Number(row.lon);
        if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) continue;
        results.push({ label: row.display_name ?? `${latitude}, ${longitude}`, latitude, longitude });
    }
    return results;
}
