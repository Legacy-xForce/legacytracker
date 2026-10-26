import type { Map as MapboxMap } from 'mapbox-gl';
import { config } from '../config';
import { storage } from './storage';

export type MapStyle = 'standard' | 'satellite';

/** Mapbox Standard's built-in lighting presets. */
export type MapLightPreset = 'dawn' | 'day' | 'dusk' | 'night';

/** What the user picked: a fixed lighting preset, or Auto to follow the local clock. */
export type MapVariant = 'auto' | MapLightPreset;

export const MAP_VARIANT_STORAGE_KEY = 'legacytracker.mapVariant';
export const DEFAULT_MAP_VARIANT: MapVariant = 'auto';

export const MAP_VARIANTS: { id: MapVariant; label: string }[] = [
    { id: 'auto', label: 'Auto' },
    { id: 'dawn', label: 'Dawn' },
    { id: 'day', label: 'Day' },
    { id: 'dusk', label: 'Dusk' },
    { id: 'night', label: 'Night' }
];

export const MAP_STYLES: { id: MapStyle; label: string }[] = [
    { id: 'standard', label: 'Standard' },
    { id: 'satellite', label: 'Satellite' }
];

/** Mapbox Standard and Standard Satellite style URLs. */
export function styleFor(style: MapStyle): string {
    return style === 'satellite' ? config.mapboxSatelliteStyle : config.mapboxStandardStyle;
}

const variantIds = new Set<string>(MAP_VARIANTS.map((variant) => variant.id));

export function isMapVariant(value: unknown): value is MapVariant {
    return typeof value === 'string' && variantIds.has(value);
}

export function getStoredMapVariant(): MapVariant {
    const stored = storage.get(MAP_VARIANT_STORAGE_KEY);
    return isMapVariant(stored) ? stored : DEFAULT_MAP_VARIANT;
}

export function setMapVariant(id: MapVariant): MapVariant {
    storage.set(MAP_VARIANT_STORAGE_KEY, id);
    return id;
}

/**
 * Auto's local-time bands: dawn 05:00–08:00, day 08:00–17:00,
 * dusk 17:00–20:00 and night through the rest of the day.
 */
export function presetForTime(at: Date | number): MapLightPreset {
    const hour = (at instanceof Date ? at : new Date(at)).getHours();
    if (hour >= 5 && hour < 8) return 'dawn';
    if (hour >= 8 && hour < 17) return 'day';
    if (hour >= 17 && hour < 20) return 'dusk';
    return 'night';
}

/** Turns the stored preference into the preset Mapbox should show now. */
export function resolveMapPreset(variant: MapVariant, at: Date | number): MapLightPreset {
    return variant === 'auto' ? presetForTime(at) : variant;
}

/**
 * Satellite imagery is photographic, so the basemap's lighting preset cannot
 * reach it: without this the tiles stay high-noon under `night`. The factors
 * dim and desaturate the raster layers to match each preset.
 */
const SATELLITE_LIGHT: Record<MapLightPreset, { brightness: number; saturation: number }> = {
    dawn: { brightness: 0.65, saturation: -0.1 },
    day: { brightness: 1, saturation: 0 },
    dusk: { brightness: 0.6, saturation: -0.05 },
    night: { brightness: 0.45, saturation: -0.25 }
};

/**
 * Applies the lighting preset to the Standard basemap import and dims any
 * raster layers (Standard Satellite's imagery) to match. Safe to call after
 * every `style.load`, because a style switch resets both.
 */
export function applyStandardTheme(map: MapboxMap, preset: MapLightPreset): void {
    try {
        map.setConfigProperty('basemap', 'lightPreset', preset);
    } catch {
        // A style that does not expose the basemap import still gets the
        // raster dimming below, so it respects the variant as far as it can.
    }
    const style = map.getStyle();
    if (!style) return;
    const light = SATELLITE_LIGHT[preset];
    for (const layer of style.layers ?? []) {
        if (layer.type !== 'raster') continue;
        map.setPaintProperty(layer.id, 'raster-brightness-min', light.brightness);
        map.setPaintProperty(layer.id, 'raster-brightness-max', light.brightness);
        map.setPaintProperty(layer.id, 'raster-saturation', light.saturation);
    }
}
