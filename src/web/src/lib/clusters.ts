/** A person's marker box (beam, badges and all), centred on their position. */
export const PEER_MARKER_SIZE: [number, number] = [152, 168];

/** The group bubble's geometry, the same as the phone app's. */
export const CLUSTER = {
    /** At most this many faces are drawn; the rest fold into a "+N" face. */
    maxFaces: 3,
    faceSize: 42,
    /** Faces overlap by 12 px. */
    faceStep: 30,
    padding: 5,
    bubbleHeight: 52,
    tailHeight: 9,
    tailHalfWidth: 8,
    dotSize: 14,
    height: 52 + 9 + 14 - 2
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
 * Groups screen points that fall within `radius` of a group's running centroid. Greedy and
 * order-dependent, like the app's; with a handful of people on screen it looks the same as an
 * optimal grouping. Returns groups of indexes into `points`.
 */
export function groupByDistance(points: { x: number; y: number }[], radius = CLUSTER_RADIUS_PX): number[][] {
    const groups: number[][] = [];
    const centroids: { x: number; y: number }[] = [];
    points.forEach((point, index) => {
        const found = centroids.findIndex((c) => Math.hypot(point.x - c.x, point.y - c.y) <= radius);
        if (found === -1) {
            groups.push([index]);
            centroids.push({ ...point });
            return;
        }
        const members = groups[found];
        members.push(index);
        centroids[found] = {
            x: members.reduce((sum, i) => sum + points[i].x, 0) / members.length,
            y: members.reduce((sum, i) => sum + points[i].y, 0) / members.length
        };
    });
    return groups;
}
