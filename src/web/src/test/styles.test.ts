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
    it('sets the basemap light preset', () => {
        const values: [string, string, unknown][] = [];
        const map = {
            setConfigProperty: (scope: string, name: string, value: unknown) => values.push([scope, name, value])
        } as unknown as MapboxMap;

        applyStandardTheme(map, 'dusk');

        expect(values).toEqual([['basemap', 'lightPreset', 'dusk']]);
    });
});
