import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { deleteHistory, type HistorySession } from '../api/history';
import TripCard from '../components/history/TripCard.vue';
import { useHistoryStore } from '../stores/history';
import { useSessionStore } from '../stores/session';
import { fakeJwt, jsonResponse, tokenResponse } from './helpers';

let fetchMock: ReturnType<typeof vi.fn>;

function trip(start: Date, minutes: number): HistorySession {
    return {
        startAt: start.getTime(),
        endAt: start.getTime() + minutes * 60_000,
        durationSeconds: minutes * 60,
        distanceMeters: 5000,
        avgSpeed: 5,
        topSpeed: 10,
        pointCount: 2,
        points: []
    };
}

function deleteCalls(): URL[] {
    return fetchMock.mock.calls
        .filter(([, init]) => (init as RequestInit | undefined)?.method === 'DELETE')
        .map(([url]) => new URL(String(url)));
}

beforeEach(async () => {
    localStorage.clear();
    setActivePinia(createPinia());
    fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    fetchMock.mockResolvedValueOnce(
        jsonResponse(tokenResponse(fakeJwt({ sub: 'u', username: 'ada', scopes: { tracker: true } })))
    );
    await useSessionStore().login('ada', 'pw');
    fetchMock.mockImplementation(async (_url: string, init?: RequestInit) =>
        init?.method === 'DELETE' ? jsonResponse({ deleted: 3 }) : jsonResponse({ sessions: [] })
    );
});

afterEach(() => vi.unstubAllGlobals());

describe('deleteHistory', () => {
    it('sends a DELETE for the window and returns how many points went', async () => {
        const from = new Date('2026-10-15T08:00:00Z');
        const to = new Date('2026-10-15T08:30:00Z');
        expect(await deleteHistory(from, to)).toBe(3);
        const [call] = deleteCalls();
        expect(call.pathname).toBe('/api/v1/history');
        expect(call.searchParams.get('from')).toBe(from.toISOString());
        expect(call.searchParams.get('to')).toBe(to.toISOString());
        expect(call.searchParams.has('user_id')).toBe(false);
    });

    it('fails when the server refuses', async () => {
        fetchMock.mockResolvedValue(jsonResponse({ error: 'x' }, 500));
        await expect(deleteHistory(new Date(0), new Date(1000))).rejects.toThrow('Tracker error (500).');
    });
});

describe('history store deletion', () => {
    async function openDay(own: boolean) {
        const history = useHistoryStore();
        history.open('u', 'Ada', own);
        await vi.waitFor(() => expect(history.monthLoading).toBe(false));
        await history.selectDay(new Date(2026, 9, 15));
        history.trips = [trip(new Date(2026, 9, 15, 8), 20), trip(new Date(2026, 9, 15, 18), 10)];
        return history;
    }

    it('deletes one trip by its start..end and drops only that trip', async () => {
        const history = await openDay(true);
        const [first, second] = history.trips;
        expect(await history.deleteTrip(first)).toBe(true);
        const [call] = deleteCalls();
        expect(call.searchParams.get('from')).toBe(new Date(first.startAt).toISOString());
        expect(call.searchParams.get('to')).toBe(new Date(first.endAt).toISOString());
        expect(history.trips).toEqual([second]);
    });

    it('stops the replay of a trip it deletes', async () => {
        const history = await openDay(true);
        const [first] = history.trips;
        history.playing = { session: first, track: {} as never };
        await history.deleteTrip(first);
        expect(history.playing).toBeNull();
    });

    it('deletes the whole local day, to its last millisecond', async () => {
        const history = await openDay(true);
        expect(await history.deleteDay()).toBe(true);
        const [call] = deleteCalls();
        expect(call.searchParams.get('from')).toBe(new Date(2026, 9, 15).toISOString());
        expect(call.searchParams.get('to')).toBe(new Date(new Date(2026, 9, 16).getTime() - 1).toISOString());
        expect(history.trips).toEqual([]);
    });

    it('reloads the month so the calendar stops marking the day', async () => {
        const history = await openDay(true);
        const before = fetchMock.mock.calls.length;
        await history.deleteDay();
        await vi.waitFor(() => {
            const afterDelete = fetchMock.mock.calls.slice(before);
            expect(afterDelete.some(([url]) => String(url).includes('points=false'))).toBe(true);
        });
    });

    it('keeps the trips and says so when the server fails', async () => {
        const history = await openDay(true);
        fetchMock.mockImplementation(async () => jsonResponse({ error: 'x' }, 500));
        expect(await history.deleteDay()).toBe(false);
        expect(history.trips).toHaveLength(2);
        expect(history.deleteError).toMatch(/Couldn't delete/);
        expect(history.deleting).toBe(false);
    });

    it("never deletes somebody else's trips", async () => {
        const history = await openDay(false);
        expect(await history.deleteTrip(history.trips[0])).toBe(false);
        expect(await history.deleteDay()).toBe(false);
        expect(deleteCalls()).toHaveLength(0);
        expect(history.trips).toHaveLength(2);
    });
});

describe('TripCard', () => {
    const session = trip(new Date(2026, 9, 15, 8), 20);

    it('offers delete only when allowed, and delete does not replay', async () => {
        const plain = mount(TripCard, { props: { session, playing: false } });
        expect(plain.find('[data-delete]').exists()).toBe(false);

        const own = mount(TripCard, { props: { session, playing: false, deletable: true } });
        await own.find('[data-delete]').trigger('click');
        expect(own.emitted('delete')).toHaveLength(1);
        expect(own.emitted('play')).toBeUndefined();

        await own.find('[data-play]').trigger('click');
        expect(own.emitted('play')).toHaveLength(1);
    });
});
