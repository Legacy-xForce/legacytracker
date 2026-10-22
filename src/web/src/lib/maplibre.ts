import { setWorkerUrl } from 'maplibre-gl';
// Vite fingerprints this asset for the production build, and serves the file directly in dev.
// Without it MapLibre looks for the worker next to the main bundle, where bundlers don't put it.
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?url';

setWorkerUrl(workerUrl);

/** MapLibre throws this from addSource/addLayer while a (new) style is still loading. */
export function isStyleNotLoaded(error: unknown): boolean {
    return error instanceof Error && /Style is not done loading/i.test(error.message);
}
