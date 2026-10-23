import type { Map as MapLibreMap } from 'maplibre-gl';
import type { LatLng } from './geo';

/** Pixels of the map hidden behind panels and controls, per side. */
export interface Insets {
    top: number;
    right: number;
    bottom: number;
    left: number;
}

export const NO_INSETS: Insets = { top: 0, right: 0, bottom: 0, left: 0 };

export interface Point {
    x: number;
    y: number;
}

function mapSize(map: MapLibreMap): Point {
    const container = map.getContainer();
    return { x: container.clientWidth, y: container.clientHeight };
}

const TILE_SIZE = 512;

/** Web Mercator world pixels at `zoom`. */
function worldPoint(at: LatLng, zoom: number): Point {
    const size = TILE_SIZE * 2 ** zoom;
    return {
        x: ((at.lng + 180) / 360) * size,
        y: ((1 - Math.asinh(Math.tan((at.lat * Math.PI) / 180)) / Math.PI) / 2) * size
    };
}

/**
 * `map.project` only works at the current zoom, but focus frames at the next one. Projecting by
 * hand keeps the maths honest without moving the camera twice.
 */
function projectAt(map: MapLibreMap, at: LatLng, zoom: number): Point {
    const size = mapSize(map);
    const centre = map.getCenter();
    const world = worldPoint(at, zoom);
    const origin = worldPoint({ lat: centre.lat, lng: centre.lng }, zoom);
    return { x: world.x - origin.x + size.x / 2, y: world.y - origin.y + size.y / 2 };
}

function unprojectAt(map: MapLibreMap, point: Point, zoom: number): LatLng {
    const size = mapSize(map);
    const centre = map.getCenter();
    const origin = worldPoint({ lat: centre.lat, lng: centre.lng }, zoom);
    const scale = TILE_SIZE * 2 ** zoom;
    const x = point.x - size.x / 2 + origin.x;
    const y = point.y - size.y / 2 + origin.y;
    return {
        lng: (x / scale) * 360 - 180,
        lat: (Math.atan(Math.sinh((1 - (2 * y) / scale) * Math.PI)) * 180) / Math.PI
    };
}

/** The middle of the part of the map that isn't covered, in container pixels. */
export function visibleCenter(map: MapLibreMap, insets: Insets): Point {
    const size = mapSize(map);
    return {
        x: insets.left + (size.x - insets.left - insets.right) / 2,
        y: insets.top + (size.y - insets.top - insets.bottom) / 2
    };
}

/** The map centre that shows `point` in the middle of the uncovered part, at `zoom`. */
export function centerShowing(map: MapLibreMap, point: LatLng, zoom: number, insets: Insets): LatLng {
    const centre = visibleCenter(map, insets);
    const size = mapSize(map);
    const projected = projectAt(map, point, zoom);
    // Shift the centre so the point lands on the visible middle, then read that centre back.
    return unprojectAt(map, { x: size.x / 2 + projected.x - centre.x, y: size.y / 2 + projected.y - centre.y }, zoom);
}

/** `fitBounds` padding that keeps what is framed clear of the panels, plus a margin. */
export function framePadding(
    insets: Insets,
    margin: number
): { padding: { top: number; right: number; bottom: number; left: number } } {
    return {
        padding: {
            top: insets.top + margin,
            right: insets.right + margin,
            bottom: insets.bottom + margin,
            left: insets.left + margin
        }
    };
}

/**
 * Pans so `point` sits at `target` on screen, for following something frame by frame. MapLibre
 * panBy with no duration does not reset the camera or reload the style, so tiles do not flash.
 */
export function holdAt(map: MapLibreMap, point: LatLng, target: Point): void {
    const projected = map.project([point.lng, point.lat]);
    const dx = Math.round(projected.x - target.x);
    const dy = Math.round(projected.y - target.y);
    if (dx !== 0 || dy !== 0) map.panBy([dx, dy], { duration: 0 });
}
