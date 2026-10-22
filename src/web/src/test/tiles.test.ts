import { describe, expect, it } from 'vitest';
import type { LayerSpecification, Map as MapLibreMap } from 'maplibre-gl';
import { applyPoiZoom } from '../lib/tiles';

const geomFilter = ['match', ['geometry-type'], ['Point'], true, false];
const treeFilter = ['match', ['get', 'class'], ['park', 'garden', 'dog_park', 'amusement_park'], false, true];

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

describe('applyPoiZoom', () => {
    it('splits bus stops into a later layer and brings other POIs in earlier', () => {
        const { map, added, filters, zoomRanges } = fakeMap();

        applyPoiZoom(map);

        expect(filters.get('poi_transit')).toEqual(['match', ['get', 'class'], ['airport', 'rail'], true, false]);
        expect(added).toHaveLength(1);
        expect(added[0].before).toBe('highway-name-path');
        expect(added[0].layer).toMatchObject({
            id: 'poi_transit_bus',
            minzoom: 18,
            filter: ['==', ['get', 'class'], 'bus']
        });
        for (const id of ['poi_r1', 'poi_r7', 'poi_r20']) {
            expect(filters.get(id)).toEqual(['all', geomFilter, treeFilter]);
        }
        expect(zoomRanges.get('poi_r1')).toEqual([14, 24]);
        expect(zoomRanges.get('poi_r7')).toEqual([15, 24]);
        expect(zoomRanges.get('poi_r20')).toEqual([16, 24]);
    });
});
