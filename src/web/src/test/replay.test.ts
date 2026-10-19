import { describe, expect, it } from 'vitest';
import {
    haversine,
    MAX_SEGMENT_MS,
    ReplayTrack,
    speedColor,
    speedSegments,
    SPEED_COLOR_MAX_KMH,
    TARGET_PLAYBACK_MS,
    type ReplayPoint
} from '../lib/replay';

function point(latitude: number, longitude: number, speed = 0): ReplayPoint {
    return { latitude, longitude, speed, heading: null, recordedAt: 0 };
}

describe('haversine', () => {
    it('measures about 111 km per degree of latitude', () => {
        expect(haversine(0, 0, 1, 0)).toBeGreaterThan(110_000);
        expect(haversine(0, 0, 1, 0)).toBeLessThan(112_000);
        expect(haversine(10, 10, 10, 10)).toBe(0);
    });
});

describe('speed colouring', () => {
    it('runs from red when stopped to green at full speed', () => {
        expect(speedColor(0)).toBe('#f44336');
        expect(speedColor(SPEED_COLOR_MAX_KMH / 3.6)).toBe('#4caf50');
        expect(speedColor(100)).toBe('#4caf50');
    });

    it('passes through amber and yellow on the way', () => {
        expect(speedColor(24 / 3.6)).not.toBe(speedColor(0));
        expect(speedColor(45 / 3.6)).not.toBe(speedColor(24 / 3.6));
        expect(speedColor(45 / 3.6)).not.toBe(speedColor(100));
    });

    it('draws consecutive fixes with similar speeds as one segment', () => {
        const steady = speedSegments([point(0, 0, 0), point(0, 0.001, 0), point(0, 0.002, 0)]);
        expect(steady).toHaveLength(1);
        expect(steady[0].color).toBe('#f44336');
        expect(steady[0].points).toHaveLength(3);
    });

    it('splits the route when the speed colour changes', () => {
        const segments = speedSegments([point(0, 0, 0), point(0, 0.001, 0), point(0, 0.002, 40)]);
        expect(segments).toHaveLength(2);
        expect(segments[0].color).toBe('#f44336');
        expect(segments[1].color).toBe('#4caf50');
        expect(segments[1].points[0]).toEqual([0, 0.001]);
    });
});

describe('ReplayTrack', () => {
    // 10 km north in 20 equal steps: past the minimum pace and under the per-segment cap, so it plays in the target time.
    const steps = Array.from({ length: 21 }, (_, i) => point(i * 0.0045, 0));
    const line = new ReplayTrack(steps);
    const three = new ReplayTrack([point(0, 0), point(0.03, 0), point(0.06, 0), point(0.09, 0)]);

    it('plays a trip in about the target time', () => {
        expect(line.duration).toBeGreaterThan(TARGET_PLAYBACK_MS * 0.95);
        expect(line.duration).toBeLessThan(TARGET_PLAYBACK_MS * 1.05);
    });

    it('starts at the first fix and ends on the last', () => {
        expect(line.positionAt(-5)).toMatchObject({ index: 0, latitude: 0 });
        expect(line.positionAt(line.duration + 1000)).toMatchObject({ index: 20 });
    });

    it('interpolates linearly inside a segment', () => {
        const half = (three.starts[1] + three.starts[2]) / 2;
        const position = three.positionAt(half);
        expect(position.index).toBe(1);
        expect(position.latitude).toBeCloseTo(0.045, 5);
    });

    it('gives each segment time in proportion to its distance', () => {
        const uneven = new ReplayTrack([point(0, 0), point(0.00004, 0), point(0.00016, 0)]);
        const first = uneven.starts[1] - uneven.starts[0];
        const second = uneven.starts[2] - uneven.starts[1];
        expect(second / first).toBeCloseTo(3, 1);
    });

    it('caps the time spent across a gap', () => {
        const short = new ReplayTrack([point(0, 0), point(0.0001, 0), point(1, 0)]);
        expect(short.starts[2] - short.starts[1]).toBeLessThanOrEqual(MAX_SEGMENT_MS);
    });

    it('copes with a single fix', () => {
        const single = new ReplayTrack([point(5, 6)]);
        expect(single.duration).toBe(0);
        expect(single.positionAt(1000)).toEqual({ index: 0, latitude: 5, longitude: 6 });
    });
});
