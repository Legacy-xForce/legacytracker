import { describe, expect, it } from 'vitest';
import type { Map as MapboxMap } from 'mapbox-gl';
import { centerShowing } from '../lib/camera';

type Padding = { top: number; right: number; bottom: number; left: number };

function fakeMap(padding?: Padding): MapboxMap {
    return {
        getContainer: () => ({ clientWidth: 1000, clientHeight: 800 }),
        getCenter: () => ({ lng: 9, lat: 45 }),
        getPadding: padding ? () => padding : undefined
    } as unknown as MapboxMap;
}

const insets = { top: 100, right: 0, bottom: 0, left: 400 };
const point = { lat: 45.1, lng: 9.2 };

describe('centerShowing', () => {
    it('moves the centre off the point by the panel, on a map with no padding', () => {
        // The visible middle is 200px right of the container's: the centre sits to the point's left.
        const centre = centerShowing(fakeMap(), point, 15, insets);
        expect(centre.lng).toBeLessThan(point.lng);
    });

    it('needs no shift when the camera padding already centres the map on the visible part', () => {
        // fitBounds leaves its padding on the camera; Mapbox then draws the centre in the padded box.
        const centre = centerShowing(fakeMap({ top: 100, right: 0, bottom: 0, left: 400 }), point, 15, insets);
        expect(centre.lng).toBeCloseTo(point.lng, 9);
        expect(centre.lat).toBeCloseTo(point.lat, 9);
    });

    it('shifts by only what the padding does not already cover', () => {
        const flat = centerShowing(fakeMap(), point, 15, insets);
        const half = centerShowing(fakeMap({ top: 0, right: 0, bottom: 0, left: 200 }), point, 15, insets);
        expect(point.lng - half.lng).toBeCloseTo((point.lng - flat.lng) / 2, 9);
    });
});
