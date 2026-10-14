import { beforeEach, describe, expect, it, vi } from 'vitest';
import { EventGeocoder } from '../lib/geocoder';
import { jsonResponse } from './helpers';

beforeEach(() => localStorage.clear());

function make(fetchMock: ReturnType<typeof vi.fn>, sleeps: number[] = []) {
    let clock = 10_000;
    return new EventGeocoder({
        fetch: fetchMock as unknown as typeof fetch,
        spacingMs: 1100,
        now: () => clock,
        sleep: async (ms) => {
            sleeps.push(ms);
            clock += ms;
        }
    });
}

describe('EventGeocoder', () => {
    it('resolves a place and remembers it, even across instances', async () => {
        const fetchMock = vi.fn().mockResolvedValue(jsonResponse([{ lat: '45.46', lon: '9.19' }]));
        const geocoder = make(fetchMock);

        expect(await geocoder.resolve('Piazza Duomo')).toEqual([45.46, 9.19]);
        expect(await geocoder.resolve('  piazza   DUOMO ')).toEqual([45.46, 9.19]);
        expect(fetchMock).toHaveBeenCalledTimes(1);
        expect(String(fetchMock.mock.calls[0][0])).toContain('q=Piazza+Duomo');

        const again = make(fetchMock);
        expect(again.peek('piazza duomo')).toEqual({ known: true, point: [45.46, 9.19] });
    });

    it('remembers that a place does not exist', async () => {
        const fetchMock = vi.fn().mockResolvedValue(jsonResponse([]));
        const geocoder = make(fetchMock);
        expect(await geocoder.resolve('Atlantis')).toBeNull();
        expect(geocoder.peek('atlantis')).toEqual({ known: true, point: null });
        await geocoder.resolve('Atlantis');
        expect(fetchMock).toHaveBeenCalledTimes(1);
    });

    it('does not remember a failed lookup', async () => {
        const fetchMock = vi
            .fn()
            .mockRejectedValueOnce(new Error('offline'))
            .mockResolvedValueOnce(jsonResponse([{ lat: '1', lon: '2' }]));
        const geocoder = make(fetchMock);
        expect(await geocoder.resolve('Home')).toBeNull();
        expect(geocoder.peek('home').known).toBe(false);
        expect(await geocoder.resolve('Home')).toEqual([1, 2]);
    });

    it('spaces consecutive lookups apart', async () => {
        const fetchMock = vi.fn().mockResolvedValue(jsonResponse([{ lat: '1', lon: '2' }]));
        const sleeps: number[] = [];
        const geocoder = make(fetchMock, sleeps);
        await Promise.all([geocoder.resolve('A'), geocoder.resolve('B'), geocoder.resolve('C')]);
        expect(fetchMock).toHaveBeenCalledTimes(3);
        expect(sleeps).toEqual([1100, 1100]);
    });
});
