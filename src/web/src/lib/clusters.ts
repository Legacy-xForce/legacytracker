/** A person's marker box (beam, badges and all), centred on their position. */
export const PEER_MARKER_SIZE: [number, number] = [152, 168];

/** The group bubble's geometry, the same as the phone app's. */
export const CLUSTER = {
    /** At most this many faces are drawn; the rest fold into a "+N" face. */
    maxFaces: 3,
    /** 44 px so a face is a full-size touch target. */
    faceSize: 44,
    /** Faces overlap by 11 px. */
    faceStep: 33,
    padding: 4,
    bubbleHeight: 52,
    tailHeight: 8,
    tailHalfWidth: 8,
    dotSize: 12,
    height: 52 + 8 + 12 - 2
} as const;

export function clusterWidth(memberCount: number): number {
    const slots = memberCount > CLUSTER.maxFaces ? CLUSTER.maxFaces + 1 : memberCount;
    return CLUSTER.padding * 2 + CLUSTER.faceSize + (slots - 1) * CLUSTER.faceStep;
}

/** Where the bubble's tail dot (the shared location) sits inside its box. */
export function clusterAnchor(memberCount: number): [number, number] {
    return [clusterWidth(memberCount) / 2, CLUSTER.height - CLUSTER.dotSize / 2];
}

/**
 * On-screen distance under which people fold into one bubble. Sized to a marker's whole
 * footprint (avatar, badges, pulse), not just the avatar, so two markers never half-overlap.
 */
export const CLUSTER_RADIUS_PX = 96;

/**
 * Real-world distance under which people may fold into one bubble. Zooming out shrinks the
 * on-screen gap between people, so the pixel radius alone would merge people kilometres apart;
 * this keeps a group meaning "actually together".
 */
export const CLUSTER_MAX_METERS = 100;

export interface GroupPoint {
    x: number;
    y: number;
    /** Real position; when both points have one, they must also be within `maxMeters`. */
    lat?: number;
    lng?: number;
}

/** Great-circle distance in metres (haversine). */
export function metersBetween(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
    const rad = Math.PI / 180;
    const dLat = (b.lat - a.lat) * rad;
    const dLng = (b.lng - a.lng) * rad;
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
    return 2 * 6371008.8 * Math.asin(Math.min(1, Math.sqrt(h)));
}

function withinMeters(a: GroupPoint, b: GroupPoint, maxMeters: number): boolean {
    if (a.lat === undefined || a.lng === undefined || b.lat === undefined || b.lng === undefined) return true;
    return metersBetween({ lat: a.lat, lng: a.lng }, { lat: b.lat, lng: b.lng }) <= maxMeters;
}

/**
 * Groups points that fall within `radius` screen pixels *and* `maxMeters` real metres of a
 * group's running centroid. Greedy and order-dependent, like the app's; with a handful of people
 * on screen it looks the same as an optimal grouping. Returns groups of indexes into `points`.
 */
export function groupByDistance(
    points: GroupPoint[],
    radius = CLUSTER_RADIUS_PX,
    maxMeters = CLUSTER_MAX_METERS
): number[][] {
    const groups: number[][] = [];
    const centroids: GroupPoint[] = [];
    points.forEach((point, index) => {
        const found = centroids.findIndex(
            (c) => Math.hypot(point.x - c.x, point.y - c.y) <= radius && withinMeters(point, c, maxMeters)
        );
        if (found === -1) {
            groups.push([index]);
            centroids.push({ ...point });
            return;
        }
        const members = groups[found];
        members.push(index);
        const mean = (key: 'x' | 'y' | 'lat' | 'lng') => {
            const values = members.map((i) => points[i][key]);
            return values.some((v) => v === undefined)
                ? undefined
                : (values as number[]).reduce((sum, v) => sum + v, 0) / members.length;
        };
        centroids[found] = { x: mean('x')!, y: mean('y')!, lat: mean('lat'), lng: mean('lng') };
    });
    return groups;
}
