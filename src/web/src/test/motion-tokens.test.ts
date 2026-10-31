import { afterEach, describe, expect, it, vi } from 'vitest';
import { duration, motion } from '../lib/motionTokens';

function reduced(matches: boolean) {
    vi.stubGlobal('matchMedia', () => ({ matches }));
}

describe('motion', () => {
    afterEach(() => vi.unstubAllGlobals());

    it('keeps a duration by default', () => {
        reduced(false);
        expect(motion(duration.long)).toBe(300);
    });

    it('is instant when the user prefers reduced motion', () => {
        reduced(true);
        expect(motion(duration.extraLong)).toBe(0);
    });
});
