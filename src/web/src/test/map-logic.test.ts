import { describe, expect, it } from 'vitest';
import { clusterAnchor, clusterWidth, groupByDistance } from '../lib/clusters';
import { latLng, sameLatLng } from '../lib/geo';
import { Motion } from '../lib/motion';
import { resolveCheckpoint, type Checkpoint } from '../stores/checkpoints';

describe('groupByDistance', () => {
    it('folds points within the radius of a group into it', () => {
        const groups = groupByDistance(
            [
                { x: 0, y: 0 },
                { x: 50, y: 0 },
                { x: 400, y: 0 },
                { x: 30, y: 60 }
            ],
            96
        );
        expect(groups).toEqual([[0, 1, 3], [2]]);
    });

    it('measures against the running centroid, not the first member', () => {
        // The second point moves the centroid to x=45, which brings the third (x=140) within reach;
        // on its own, x=140 is too far from x=0.
        expect(
            groupByDistance(
                [
                    { x: 0, y: 0 },
                    { x: 90, y: 0 },
                    { x: 140, y: 0 }
                ],
                96
            )
        ).toEqual([[0, 1, 2]]);
        expect(
            groupByDistance(
                [
                    { x: 0, y: 0 },
                    { x: 140, y: 0 }
                ],
                96
            )
        ).toEqual([[0], [1]]);
    });
});

describe('groupByDistance real-world limit', () => {
    // 0.0005 deg of latitude is about 55 m; 0.005 is about 555 m.
    it('keeps people apart when zoomed out far enough that pixels are close but metres are not', () => {
        const near = groupByDistance([
            { x: 0, y: 0, lat: 45, lng: 9 },
            { x: 5, y: 0, lat: 45.0005, lng: 9 }
        ]);
        expect(near).toEqual([[0, 1]]);
        const far = groupByDistance([
            { x: 0, y: 0, lat: 45, lng: 9 },
            { x: 5, y: 0, lat: 45.005, lng: 9 }
        ]);
        expect(far).toEqual([[0], [1]]);
    });

    it('still requires the pixel radius when people are close in metres', () => {
        expect(
            groupByDistance([
                { x: 0, y: 0, lat: 45, lng: 9 },
                { x: 400, y: 0, lat: 45.0005, lng: 9 }
            ])
        ).toEqual([[0], [1]]);
    });
});

describe('group bubble', () => {
    it('grows a face at a time and folds the rest into "+N"', () => {
        expect(clusterWidth(2)).toBe(73);
        expect(clusterWidth(3)).toBe(100);
        // Four or more: three faces plus the "+N" face.
        expect(clusterWidth(4)).toBe(127);
        expect(clusterWidth(9)).toBe(127);
    });

    it('sits on the location by the dot at the tip of its tail', () => {
        expect(clusterAnchor(2)).toEqual([36.5, 58]);
    });
});

describe('Motion', () => {
    const a = latLng(45, 9);
    const b = latLng(45.01, 9);

    it('glides linearly to a new position, longer than the gap since the previous update', () => {
        const motion = new Motion(a);
        motion.moveTo(b, 0); // first update: one-second glide
        motion.step(500);
        expect(motion.shown.lat).toBeCloseTo(45.005, 6);
        motion.step(1000);
        expect(sameLatLng(motion.shown, b)).toBe(true);
        expect(motion.gliding).toBe(false);

        // Two seconds later: the next glide lasts 3 seconds (1.5 x the 2 s gap), so it is still moving
        // when the following fix is due.
        motion.moveTo(a, 2000);
        motion.step(3500);
        expect(motion.shown.lat).toBeCloseTo(45.005, 6);
        motion.step(4900);
        expect(motion.gliding).toBe(true);
    });

    it('carries on through the waypoint it has not reached instead of cutting the corner', () => {
        const motion = new Motion(a);
        motion.moveTo(b, 0);
        motion.step(500); // halfway to b
        const c = latLng(45.01, 9.01);
        motion.moveTo(c, 500);
        // Remaining route: 0.005 north, then 0.01 east (scaled); its first third ends at b's latitude.
        motion.step(500 + 750 * 0.2);
        expect(motion.shown.lng).toBe(9);
        motion.step(500 + 750 * 0.9);
        expect(motion.shown.lng).toBeGreaterThan(9);
        expect(motion.shown.lat).toBeCloseTo(45.01, 6);
    });

    it('keeps glides between 0.3 and 4 seconds', () => {
        const motion = new Motion(a);
        motion.moveTo(b, 0);
        motion.moveTo(latLng(45.02, 9), 10); // 10 ms later: floored at 300 ms
        motion.step(160);
        expect(motion.gliding).toBe(true);
        motion.step(320);
        expect(motion.gliding).toBe(false);
    });

    it('ignores an update to where it is already heading', () => {
        const motion = new Motion(a);
        expect(motion.moveTo(a, 0)).toBe(false);
    });
});

describe('resolveCheckpoint', () => {
    const place = (id: string, latitude: number, radius: number): Checkpoint => ({
        id,
        name: id,
        latitude,
        longitude: 9,
        radius
    });

    it('finds the place a point is inside', () => {
        expect(resolveCheckpoint(45.0005, 9, [place('home', 45, 100)])?.id).toBe('home');
        expect(resolveCheckpoint(45.01, 9, [place('home', 45, 100)])).toBeNull();
    });

    it('prefers the smallest of overlapping places', () => {
        const found = resolveCheckpoint(45, 9, [place('district', 45, 250), place('home', 45.0002, 40)]);
        expect(found?.id).toBe('home');
    });
});
