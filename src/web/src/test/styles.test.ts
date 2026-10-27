import { beforeEach, describe, expect, it } from 'vitest';
import type { Map as MapboxMap } from 'mapbox-gl';
import {
    applyStandardTheme,
    DEFAULT_MAP_VARIANT,
    getStoredMapVariant,
    isMapVariant,
    MAP_VARIANT_STORAGE_KEY,
    MAP_VARIANTS,
    MAP_STYLES,
    presetForTime,
    resolveMapPreset,
    setMapVariant,
    styleFor
} from '../lib/styles';
import { config } from '../config';

describe('styleFor', () => {
    it('uses Mapbox Standard for the standard map', () => {
        expect(styleFor('standard')).toBe(config.mapboxStandardStyle);
        expect(config.mapboxStandardStyle).toBe('mapbox://styles/mapbox/standard');
    });

    it('uses Mapbox Standard Satellite for the satellite map', () => {
        expect(styleFor('satellite')).toBe(config.mapboxSatelliteStyle);
        expect(config.mapboxSatelliteStyle).toBe('mapbox://styles/mapbox/standard-satellite');
    });

    it('offers only Standard and Satellite', () => {
        expect(MAP_STYLES.map((style) => style.id)).toEqual(['standard', 'satellite']);
    });
});

describe('map variants', () => {
    beforeEach(() => localStorage.clear());

    it('offers Auto plus the four lighting presets', () => {
        expect(MAP_VARIANTS.map((variant) => variant.id)).toEqual(['auto', 'dawn', 'day', 'dusk', 'night']);
        expect(MAP_VARIANT_STORAGE_KEY).toBe('legacytracker.mapVariant');
    });

    it('defaults to Auto and ignores unknown stored values', () => {
        expect(DEFAULT_MAP_VARIANT).toBe('auto');
        expect(getStoredMapVariant()).toBe('auto');

        localStorage.setItem(MAP_VARIANT_STORAGE_KEY, 'noon');
        expect(getStoredMapVariant()).toBe('auto');
        expect(isMapVariant('noon')).toBe(false);
    });

    it('reads and persists a fixed variant', () => {
        expect(setMapVariant('dusk')).toBe('dusk');
        expect(getStoredMapVariant()).toBe('dusk');

        localStorage.setItem(MAP_VARIANT_STORAGE_KEY, 'night');
        expect(getStoredMapVariant()).toBe('night');
    });
});

describe('presetForTime', () => {
    const at = (hour: number) => new Date(2026, 0, 1, hour, 0);

    it('follows the local clock', () => {
        expect(presetForTime(at(0))).toBe('night');
        expect(presetForTime(at(4))).toBe('night');
        expect(presetForTime(at(5))).toBe('dawn');
        expect(presetForTime(at(7))).toBe('dawn');
        expect(presetForTime(at(8))).toBe('day');
        expect(presetForTime(at(16))).toBe('day');
        expect(presetForTime(at(17))).toBe('dusk');
        expect(presetForTime(at(19))).toBe('dusk');
        expect(presetForTime(at(20))).toBe('night');
        expect(presetForTime(at(23))).toBe('night');
    });

    it('accepts a timestamp as well as a Date', () => {
        expect(presetForTime(at(9).getTime())).toBe('day');
    });
});

describe('resolveMapPreset', () => {
    it('uses the chosen preset regardless of the clock', () => {
        expect(resolveMapPreset('dawn', new Date(2026, 0, 1, 23, 0))).toBe('dawn');
        expect(resolveMapPreset('night', new Date(2026, 0, 1, 12, 0))).toBe('night');
    });

    it('follows the clock in Auto', () => {
        expect(resolveMapPreset('auto', new Date(2026, 0, 1, 12, 0))).toBe('day');
        expect(resolveMapPreset('auto', new Date(2026, 0, 1, 22, 0))).toBe('night');
    });
});

describe('applyStandardTheme', () => {
    function harness(configThrows = false) {
        const values: [string, string, unknown][] = [];
        const paints: [string, string, unknown][] = [];
        const map = {
            setConfigProperty: (scope: string, name: string, value: unknown) => {
                if (configThrows) throw new Error(`no import ${scope}`);
                values.push([scope, name, value]);
            },
            getStyle: () => ({
                layers: [
                    { id: 'satellite', type: 'raster' },
                    { id: 'roads', type: 'line' }
                ]
            }),
            setPaintProperty: (layer: string, name: string, value: unknown) => paints.push([layer, name, value])
        } as unknown as MapboxMap;
        return { map, values, paints };
    }

    it('sets the basemap light preset and dims the satellite imagery to match', () => {
        const { map, values, paints } = harness();

        applyStandardTheme(map, 'dusk');

        expect(values).toEqual([['basemap', 'lightPreset', 'dusk']]);
        // Only the raster layers take the dimming.
        expect(paints).toEqual([
            ['satellite', 'raster-brightness-min', 0.6],
            ['satellite', 'raster-brightness-max', 0.6],
            ['satellite', 'raster-saturation', -0.05]
        ]);
    });

    it('restores the imagery at full brightness for day', () => {
        const { map, paints } = harness();

        applyStandardTheme(map, 'day');

        expect(paints).toEqual([
            ['satellite', 'raster-brightness-min', 1],
            ['satellite', 'raster-brightness-max', 1],
            ['satellite', 'raster-saturation', 0]
        ]);
    });

    it('still dims the imagery when the style has no basemap import', () => {
        const { map, values, paints } = harness(true);

        applyStandardTheme(map, 'night');

        expect(values).toEqual([]);
        expect(paints.map(([, name]) => name)).toEqual([
            'raster-brightness-min',
            'raster-brightness-max',
            'raster-saturation'
        ]);
        expect(paints).toContainEqual(['satellite', 'raster-brightness-max', 0.45]);
    });

    it('survives a style that is not done loading', () => {
        // The initial mount calls this before the style exists; throwing
        // here killed PeersMap's onMounted and left every layer on the map
        // (replay included) without a map to draw on.
        const map = {
            setConfigProperty: () => {
                throw new Error('Style is not done loading.');
            },
            getStyle: () => {
                throw new Error('Style is not done loading.');
            }
        } as unknown as MapboxMap;

        expect(() => applyStandardTheme(map, 'dusk')).not.toThrow();
    });
});
