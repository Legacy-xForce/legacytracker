/// <reference types="node" />
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { AVATAR_COLORS, contrastRatio, initialColor } from '../lib/avatars';
import { palette } from '../lib/palette';

const dart = readFileSync(resolve(process.cwd(), '../client/lib/src/core/palette.dart'), 'utf8').toLowerCase();
const hex = (value: string) => value.slice(1).toLowerCase();

describe('palette', () => {
    it('matches the phone app, so people and events look the same on both', () => {
        const shared = [
            palette.mapAccent,
            palette.stale,
            palette.staleBadge,
            palette.eventFallback,
            palette.onMedal,
            ...palette.medals,
            ...AVATAR_COLORS
        ];
        for (const colour of shared) expect(dart, colour).toContain(`0xff${hex(colour)}`);
    });

    it('keeps the initial readable on every avatar colour', () => {
        for (const colour of AVATAR_COLORS) {
            expect(contrastRatio(initialColor(colour), colour)).toBeGreaterThanOrEqual(4.5);
        }
    });

    it('keeps the podium label readable on every medal', () => {
        for (const medal of palette.medals) {
            expect(contrastRatio(palette.onMedal, medal)).toBeGreaterThanOrEqual(4.5);
        }
    });
});
