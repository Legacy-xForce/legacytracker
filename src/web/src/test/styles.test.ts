import { describe, expect, it } from 'vitest';
import type { Map as MapboxMap } from 'mapbox-gl';
import { applyStandardTheme, lightPresetFor, MAP_STYLES, styleFor } from '../lib/styles';
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

describe('lightPresetFor', () => {
    it('matches the app theme to a Standard lighting preset', () => {
        expect(lightPresetFor('dark')).toBe('night');
        expect(lightPresetFor('light')).toBe('day');
    });
});

describe('applyStandardTheme', () => {
    it('sets the basemap light preset', () => {
        const values: [string, string, unknown][] = [];
        const map = {
            setConfigProperty: (scope: string, name: string, value: unknown) => values.push([scope, name, value])
        } as unknown as MapboxMap;

        applyStandardTheme(map, 'night');

        expect(values).toEqual([['basemap', 'lightPreset', 'night']]);
    });
});
