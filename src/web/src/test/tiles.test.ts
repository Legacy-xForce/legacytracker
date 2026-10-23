import { describe, expect, it, vi } from 'vitest';
import type { LayerSpecification, Map as MapLibreMap, StyleSpecification } from 'maplibre-gl';
import { applyPoiZoom, styleFor, type PoiOverlay } from '../lib/tiles';
import { config } from '../config';

const geomFilter = ['match', ['geometry-type'], ['Point'], true, false];
const hiddenFilter = ['match', ['get', 'class'], ['bus', 'park', 'garden', 'dog_park', 'amusement_park'], false, true];

function fakeMap() {
    const layers = [
        { id: 'poi_r1', type: 'symbol', minzoom: 15, filter: geomFilter },
        { id: 'poi_r7', type: 'symbol', minzoom: 16, filter: geomFilter },
        { id: 'poi_r20', type: 'symbol', minzoom: 17, filter: geomFilter },
        {
            id: 'poi_transit',
            type: 'symbol',
            filter: ['match', ['get', 'class'], ['airport', 'bus', 'rail'], true, false]
        },
        { id: 'highway-name-path', type: 'symbol', minzoom: 15.5 }
    ] as unknown as LayerSpecification[];
    const added: { layer: LayerSpecification; before?: string }[] = [];
    const filters = new Map<string, unknown>();
    const zoomRanges = new Map<string, [number, number]>();
    const map = {
        getStyle: () => ({ layers }),
        getLayer: (id: string) => layers.find((layer) => layer.id === id),
        addLayer: (layer: LayerSpecification, before?: string) => added.push({ layer, before }),
        setFilter: (id: string, filter: unknown) => filters.set(id, filter),
        setLayerZoomRange: (id: string, min: number, max: number) => zoomRanges.set(id, [min, max])
    } as unknown as MapLibreMap;
    return { map, added, filters, zoomRanges };
}
const overlay: PoiOverlay = {
    sprite: 'https://tiles.openfreemap.org/sprites/ofm_f384/ofm',
    glyphs: 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
    source: { type: 'vector', url: 'https://tiles.openfreemap.org/planet' },
    layers: [
        {
            id: 'poi_transit',
            type: 'symbol',
            source: 'openmaptiles',
            'source-layer': 'poi',
            layout: { 'icon-image': ['to-string', ['get', 'class']] }
        }
    ]
};

/** The style config the overlay is borrowed from, as the vector style would serve it. */
const libertyLike = {
    version: 8,
    sprite: overlay.sprite,
    glyphs: overlay.glyphs,
    sources: {
        openmaptiles: overlay.source,
        other: { type: 'raster', tiles: ['https://example.test/{z}/{x}/{y}.png'] }
    },
    layers: [
        { id: 'poi_transit', type: 'symbol', source: 'openmaptiles', 'source-layer': 'poi' },
        { id: 'poi_r1', type: 'symbol', source: 'openmaptiles', 'source-layer': 'poi' },
        { id: 'road', type: 'line', source: 'openmaptiles', 'source-layer': 'transportation' }
    ]
} satisfies StyleSpecification;

function asStyle(style: string | StyleSpecification): StyleSpecification {
    if (typeof style === 'string') throw new Error('expected a style object');
    return style;
}

describe('applyPoiZoom', () => {
    it('drops bus stops entirely and brings other POIs in earlier', () => {
        const { map, added, filters, zoomRanges } = fakeMap();

        applyPoiZoom(map);

        // Bus stops also arrive through the ranked layers, so they are filtered out of those too.
        expect(added).toEqual([]);
        expect(filters.get('poi_transit')).toEqual(['match', ['get', 'class'], ['airport', 'rail'], true, false]);
        for (const id of ['poi_r1', 'poi_r7', 'poi_r20']) {
            expect(filters.get(id)).toEqual(['all', geomFilter, hiddenFilter]);
        }
        expect(zoomRanges.get('poi_r1')).toEqual([14, 24]);
        expect(zoomRanges.get('poi_r7')).toEqual([15, 24]);
        expect(zoomRanges.get('poi_r20')).toEqual([16, 24]);
    });
});

describe('styleFor', () => {
    it('overlays the vector POIs, sprite and glyphs on the satellite imagery', () => {
        const style = asStyle(styleFor('satellite', overlay));

        expect(style.sprite).toBe(overlay.sprite);
        expect(style.glyphs).toBe(overlay.glyphs);
        expect(style.sources.openmaptiles).toEqual(overlay.source);
        expect(style.layers.map((layer) => layer.id)).toEqual([
            'background',
            'esri-imagery',
            'esri-reference',
            'poi_transit'
        ]);
        // The raster imagery sits under the POIs so the symbols stay readable.
        expect(style.layers[1]).toMatchObject({ type: 'raster', source: 'esri-imagery' });
    });

    it('overlays the same POIs on the terrain raster', () => {
        const style = asStyle(styleFor('terrain', overlay));

        expect(style.sources.openmaptiles).toEqual(overlay.source);
        expect(style.layers.map((layer) => layer.id)).toEqual(['background', 'opentopomap', 'poi_transit']);
    });

    it('keeps the raster styles plain when no overlay is available', () => {
        const style = asStyle(styleFor('satellite', null));

        expect(style.sprite).toBeUndefined();
        expect(style.glyphs).toBeUndefined();
        expect(style.sources.openmaptiles).toBeUndefined();
        expect(style.layers.map((layer) => layer.id)).toEqual(['background', 'esri-imagery', 'esri-reference']);
    });

    it('returns the configured vector style for standard', () => {
        expect(styleFor('standard', overlay)).toBe(config.mapStyleUrl);
    });
});

describe('preloadPoiOverlay', () => {
    it('borrows only the POI layers, caches them, and retries after a failure', async () => {
        vi.resetModules();
        const fetchMock = vi
            .fn()
            .mockRejectedValueOnce(new Error('offline'))
            .mockResolvedValueOnce({ ok: true, json: async () => libertyLike });
        vi.stubGlobal('fetch', fetchMock);

        try {
            const tiles = await import('../lib/tiles');

            // A failed fetch leaves the raster styles plain but is not cached.
            expect(await tiles.preloadPoiOverlay()).toBeNull();
            const overlay = await tiles.preloadPoiOverlay();
            expect(overlay?.layers.map((layer) => layer.id)).toEqual(['poi_transit', 'poi_r1']);
            expect(overlay?.source).toEqual(libertyLike.sources.openmaptiles);

            // Cached: a third call does not hit the network again.
            expect(await tiles.preloadPoiOverlay()).toBe(overlay);
            expect(fetchMock).toHaveBeenCalledTimes(2);
        } finally {
            vi.unstubAllGlobals();
        }
    });
});
