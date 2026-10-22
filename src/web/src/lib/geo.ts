/** A WGS84 position. Kept plain so map-independent logic stays easy to test. */
export interface LatLng {
    lat: number;
    lng: number;
}

export function latLng(lat: number, lng: number): LatLng {
    return { lat, lng };
}

export function sameLatLng(a: LatLng, b: LatLng): boolean {
    return a.lat === b.lat && a.lng === b.lng;
}

/** Mean position of a non-empty list, as the app's cluster bubbles use. */
export function centroid(points: LatLng[]): LatLng {
    let lat = 0;
    let lng = 0;
    for (const point of points) {
        lat += point.lat;
        lng += point.lng;
    }
    return latLng(lat / points.length, lng / points.length);
}

/** South-west and north-east corners, the `[[west, south], [east, north]]` MapLibre accepts. */
export function boundsOf(points: LatLng[]): [[number, number], [number, number]] {
    if (points.length === 0)
        return [
            [-180, -85.0511],
            [180, 85.0511]
        ];
    let west = Infinity;
    let south = Infinity;
    let east = -Infinity;
    let north = -Infinity;
    for (const point of points) {
        west = Math.min(west, point.lng);
        east = Math.max(east, point.lng);
        south = Math.min(south, point.lat);
        north = Math.max(north, point.lat);
    }
    return [
        [west, south],
        [east, north]
    ];
}

const EARTH_RADIUS_M = 6_371_008.8;

/**
 * A closed ring approximating a circle of `radius` metres around `center`, as `[lng, lat]`
 * pairs, because MapLibre draws circles as GeoJSON geometry.
 */
export function circlePolygon(center: LatLng, radius: number, steps = 64): [number, number][] {
    const ring: [number, number][] = [];
    const angular = radius / EARTH_RADIUS_M;
    const lat = (center.lat * Math.PI) / 180;
    const lng = (center.lng * Math.PI) / 180;
    for (let i = 0; i < steps; i++) {
        const bearing = (i / steps) * Math.PI * 2;
        const lat2 = Math.asin(
            Math.sin(lat) * Math.cos(angular) + Math.cos(lat) * Math.sin(angular) * Math.cos(bearing)
        );
        const lng2 =
            lng +
            Math.atan2(
                Math.sin(bearing) * Math.sin(angular) * Math.cos(lat),
                Math.cos(angular) - Math.sin(lat) * Math.sin(lat2)
            );
        ring.push([normalizeLongitude((lng2 * 180) / Math.PI), (lat2 * 180) / Math.PI]);
    }
    ring.push(ring[0]);
    return ring;
}

function normalizeLongitude(lng: number): number {
    return ((((lng + 180) % 360) + 360) % 360) - 180;
}
