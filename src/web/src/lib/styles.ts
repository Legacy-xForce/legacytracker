import type { Map as MapboxMap } from 'mapbox-gl';
import { config } from '../config';

export type MapStyle = 'standard' | 'satellite';

/** Mapbox Standard's built-in lighting presets that match the app's themes. */
export type MapLightPreset = 'day' | 'night';

export const MAP_STYLES: { id: MapStyle; label: string }[] = [
    { id: 'standard', label: 'Standard' },
    { id: 'satellite', label: 'Satellite' }
];

/** Mapbox Standard and Standard Satellite style URLs. */
export function styleFor(style: MapStyle): string {
    return style === 'satellite' ? config.mapboxSatelliteStyle : config.mapboxStandardStyle;
}

/** Dark themes use Standard's night lighting; light themes use day. */
export function lightPresetFor(mode: 'dark' | 'light'): MapLightPreset {
    return mode === 'dark' ? 'night' : 'day';
}

/**
 * Applies the lighting preset to the Standard basemap import. Safe to call
 * after every `style.load`, because a style switch resets the configuration.
 */
export function applyStandardTheme(map: MapboxMap, preset: MapLightPreset): void {
    map.setConfigProperty('basemap', 'lightPreset', preset);
}
