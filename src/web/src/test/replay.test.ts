import { describe, expect, it } from 'vitest';
import { haversine, MAX_SEGMENT_MS, ReplayTrack, TARGET_PLAYBACK_MS, type ReplayPoint } from '../lib/replay';

function point(latitude: number, longitude: number): ReplayPoint {
    return { latitude, longitude, speed: 0, heading: null, recordedAt: 0 };
}

describe('haversine', () => {
    it('measures about 111 km per degree of latitude', () => {
        expect(haversine(0, 0, 1, 0)).toBeGreaterThan(110_000);
        expect(haversine(0, 0, 1, 0)).toBeLessThan(112_000);
        expect(haversine(10, 10, 10, 10)).toBe(0);
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
