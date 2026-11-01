import { describe, expect, it } from 'vitest';
import { formatSpeed, msToKmh, plural } from '../lib/format';

describe('format helpers', () => {
    it('converts metres per second to whole km/h', () => {
        expect(msToKmh(10)).toBeCloseTo(36);
        expect(formatSpeed(10)).toBe('36 km/h');
        expect(formatSpeed(0)).toBe('0 km/h');
    });

    it('pluralises by count', () => {
        expect(plural(1, 'trip')).toBe('1 trip');
        expect(plural(3, 'trip')).toBe('3 trips');
        expect(plural(0, 'address', 'addresses')).toBe('0 addresses');
    });
});
