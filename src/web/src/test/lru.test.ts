import { describe, expect, it } from 'vitest';
import { trimOldest } from '../lib/lru';

describe('trimOldest', () => {
    it('keeps the newest entries', () => {
        const map = new Map([
            ['a', 1],
            ['b', 2],
            ['c', 3]
        ]);
        trimOldest(map, 2);
        expect([...map.keys()]).toEqual(['b', 'c']);
        trimOldest(map, 5);
        expect(map.size).toBe(2);
    });
});
