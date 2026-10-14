import { describe, expect, it, vi } from 'vitest';
import { describeAddress, NO_ADDRESS, StreetNames } from '../lib/streets';
import { Throttle } from '../lib/throttle';
import { jsonResponse } from './helpers';

function deferred() {
    let release!: () => void;
    const promise = new Promise<void>((resolve) => (release = resolve));
    return { promise, release };
}

describe('describeAddress', () => {
    it('names the street, its number and the town, like the app', () => {
        expect(describeAddress({ address: { road: 'Via Roma', house_number: '12', city: 'Torino' } })).toBe(
            'Via Roma 12, Torino'
        );
        expect(describeAddress({ address: { pedestrian: 'Piazza Castello', town: 'Torino' } })).toBe(
            'Piazza Castello, Torino'
        );
    });

    it('falls back to the town, then the full name, then says it has none', () => {
        expect(describeAddress({ address: { village: 'Ceres' } })).toBe('Ceres');
        expect(describeAddress({ display_name: ' Somewhere ' })).toBe('Somewhere');
        expect(describeAddress({})).toBe(NO_ADDRESS);
    });
});

describe('StreetNames', () => {
    it('looks up only the newest position of someone on the move', async () => {
        const gate = deferred();
        const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ address: { road: 'Via Po' } }));
        // The first turn is slow to come while three more fixes for the same person arrive.
        const throttle = new Throttle({ spacingMs: 0 });
        const acquire = vi.spyOn(throttle, 'acquire').mockImplementationOnce(() => gate.promise);
        const names = new StreetNames({ fetch: fetchMock as unknown as typeof fetch, throttle });

        names.request('ada', 45.0, 7.0);
        names.request('ada', 45.1, 7.0);
        names.request('ada', 45.2, 7.0);
        names.request('ada', 45.3, 7.0);
        gate.release();
        await vi.waitFor(() => expect(names.peek(45.3, 7.0)).toBe('Via Po'));

        // The fixes that arrived while waiting replaced each other: one lookup, for the newest.
        expect(fetchMock).toHaveBeenCalledTimes(1);
        expect(String(fetchMock.mock.calls[0][0])).toContain('lat=45.3');
        expect(acquire).toHaveBeenCalledTimes(1);
    });

    it('asks once per place, and not at all for a cancelled subject', async () => {
        const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ address: { road: 'Via Po' } }));
        const names = new StreetNames({
            fetch: fetchMock as unknown as typeof fetch,
            throttle: new Throttle({ spacingMs: 0 })
        });
        names.request('a', 45, 7);
        await vi.waitFor(() => expect(names.peek(45, 7)).toBe('Via Po'));
        names.request('b', 45.00001, 7.00001); // same ~11 m cell
        names.request('c', 46, 8);
        names.cancel('c');
        await new Promise((r) => setTimeout(r, 10));
        expect(fetchMock).toHaveBeenCalledTimes(1);
    });
});
