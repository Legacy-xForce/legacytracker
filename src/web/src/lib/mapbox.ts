import mapboxgl from 'mapbox-gl';
import { config } from '../config';

// Every Mapbox SDK call uses this token. The web ships a public token
// restricted to the app's origins; the phone app gets a temporary one from the
// backend instead.
mapboxgl.accessToken = config.mapboxToken || null;

/** Fails early with an actionable message when a local build lost its token. */
export function assertMapboxConfigured(): void {
    if (!config.mapboxToken) {
        throw new Error(
            'VITE_MAPBOX_TOKEN is missing. Set the Mapbox public token in .env.local or the build environment (see docs/mapbox.md).'
        );
    }
}

/** Mapbox throws this from addSource/addLayer while a (new) style is still loading. */
export function isStyleNotLoaded(error: unknown): boolean {
    return error instanceof Error && /Style is not done loading/i.test(error.message);
}
