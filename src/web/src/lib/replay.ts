/** One recorded fix of a travel session. */
export interface ReplayPoint {
    latitude: number;
    longitude: number;
    /** m/s */
    speed: number;
    heading: number | null;
    /** Epoch ms. */
    recordedAt: number;
}

// Same pacing as the phone app. On-screen speed is constant whatever the recorded speed was: points
// are stored adaptively (dense through turns, sparse on straights), so each glide lasts in
// proportion to the distance it covers. A fixed time per segment would race down straights and
// crawl through corners.
export const TARGET_PLAYBACK_MS = 40_000;
/** Every speed option plays this many times faster than the base pace: "1x" covers a trip in ~20 s. */
export const BASE_SPEED = 2;
export const MIN_PACE_MPS = 5;
export const MIN_SEGMENT_MS = 16;
export const MAX_SEGMENT_MS = 3_000;
export const PLAYBACK_SPEEDS = [1, 2, 4] as const;

/** Speed (km/h) at which the replay line is fully green. Slower speeds fade through amber. */
export const SPEED_COLOR_MAX_KMH = 70;

/** Red at a standstill, orange and yellow through the middle, green at full speed. */
const SPEED_COLOR_STOPS: readonly (readonly [number, readonly [number, number, number]])[] = [
    [0, [244, 67, 54]],
    [0.35, [255, 152, 0]],
    [0.65, [255, 235, 59]],
    [1, [76, 175, 80]]
];

/** Nearby speeds share a colour, so consecutive segments merge into one polyline. */
const SPEED_COLOR_STEPS = 16;

export interface ReplaySegment {
    /** `[latitude, longitude]` pairs for this run of the route. */
    points: [number, number][];
    color: string;
}

/**
 * Colour for a recorded speed (m/s): red when slow, green when fast. Quantised so
 * a route made of tiny speed changes still draws as a handful of polylines.
 */
export function speedColor(speedMps: number): string {
    const kmh = Number.isFinite(speedMps) ? Math.max(0, speedMps) * 3.6 : 0;
    const step = Math.round(Math.min(1, kmh / SPEED_COLOR_MAX_KMH) * SPEED_COLOR_STEPS) / SPEED_COLOR_STEPS;
    let index = 0;
    while (index < SPEED_COLOR_STOPS.length - 2 && step > SPEED_COLOR_STOPS[index + 1][0]) index++;
    const [start, from] = SPEED_COLOR_STOPS[index];
    const [end, to] = SPEED_COLOR_STOPS[index + 1];
    const t = end === start ? 0 : (step - start) / (end - start);
    const channels = from.map((value, channel) => Math.round(value + (to[channel] - value) * t));
    return `#${channels.map((value) => value.toString(16).padStart(2, '0')).join('')}`;
}

/** The route split into runs with the same speed colour, ready for Leaflet polylines. */
export function speedSegments(points: ReplayPoint[]): ReplaySegment[] {
    const segments: ReplaySegment[] = [];
    for (let i = 1; i < points.length; i++) {
        const a = points[i - 1];
        const b = points[i];
        const color = speedColor((a.speed + b.speed) / 2);
        const last = segments[segments.length - 1];
        if (last?.color === color) last.points.push([b.latitude, b.longitude]);
        else
            segments.push({
                points: [
                    [a.latitude, a.longitude],
                    [b.latitude, b.longitude]
                ],
                color
            });
    }
    return segments;
}

const EARTH_RADIUS_M = 6_371_000;

/** Great-circle distance in metres. */
export function haversine(aLat: number, aLon: number, bLat: number, bLon: number): number {
    const rad = Math.PI / 180;
    const dLat = (bLat - aLat) * rad;
    const dLon = (bLon - aLon) * rad;
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(aLat * rad) * Math.cos(bLat * rad) * Math.sin(dLon / 2) ** 2;
    return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

export interface ReplayPosition {
    /** Index of the fix the marker has most recently passed. */
    index: number;
    latitude: number;
    longitude: number;
}

/** A session's route, timed so a whole trip plays in about the target time at 1x. */
export class ReplayTrack {
    /** Playback time (ms, at 1x pace) at which each fix is reached; the first is 0. */
    readonly starts: number[] = [0];

    constructor(readonly points: ReplayPoint[]) {
        const meters: number[] = [];
        for (let i = 1; i < points.length; i++) {
            const a = points[i - 1];
            const b = points[i];
            meters.push(haversine(a.latitude, a.longitude, b.latitude, b.longitude));
        }
        const total = meters.reduce((sum, m) => sum + m, 0);
        const pace = Math.max(total / (TARGET_PLAYBACK_MS / 1000), MIN_PACE_MPS);
        for (const m of meters) {
            const ms = Math.min(MAX_SEGMENT_MS, Math.max(MIN_SEGMENT_MS, (m / pace) * 1000));
            this.starts.push(this.starts[this.starts.length - 1] + ms);
        }
    }

    /** Total playback time at 1x pace. */
    get duration(): number {
        return this.starts[this.starts.length - 1];
    }

    /** Where the marker is `elapsed` ms into the (1x pace) playback, interpolating linearly between fixes. */
    positionAt(elapsed: number): ReplayPosition {
        const points = this.points;
        if (elapsed <= 0 || points.length === 1) {
            return { index: 0, latitude: points[0].latitude, longitude: points[0].longitude };
        }
        const last = points.length - 1;
        if (elapsed >= this.duration) {
            return { index: last, latitude: points[last].latitude, longitude: points[last].longitude };
        }
        // Binary search for the segment containing `elapsed`.
        let low = 0;
        let high = last - 1;
        while (low < high) {
            const mid = (low + high + 1) >> 1;
            if (this.starts[mid] <= elapsed) low = mid;
            else high = mid - 1;
        }
        const a = points[low];
        const b = points[low + 1];
        const span = this.starts[low + 1] - this.starts[low];
        const t = span > 0 ? (elapsed - this.starts[low]) / span : 1;
        return {
            index: low,
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        };
    }
}
