import mapboxgl from 'mapbox-gl';
import { config } from '../config';

// Every Mapbox SDK call uses this token. The web ships a public token
// restricted to the app's origins; the phone app gets a temporary one from the
// backend instead.
mapboxgl.accessToken = config.mapboxToken || null;

/**
 * Warns if the Mapbox token is missing. The token is committed in .env, so
 * this should not happen unless .env is deleted. The map will still fail to
 * load styles at runtime, but the build does not fail.
 */
export function assertMapboxConfigured(): void {
    if (!config.mapboxToken) {
        console.warn(
            'VITE_MAPBOX_TOKEN is missing. Mapbox styles will not load. Set the Mapbox public token in .env or the build environment (see docs/mapbox.md).'
        );
    }
}

/** Mapbox throws this from addSource/addLayer while a (new) style is still loading. */
export function isStyleNotLoaded(error: unknown): boolean {
    return error instanceof Error && /Style is not done loading/i.test(error.message);
}
