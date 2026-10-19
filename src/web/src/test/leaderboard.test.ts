import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { nextTick } from 'vue';
import { parseLeaderboard } from '../api/leaderboard';
import TravelLeaderboard from '../components/travel/TravelLeaderboard.vue';
import {
    customPeriod,
    formatPeriod,
    fromDateInput,
    isCurrentOrLater,
    periodContaining,
    periodDays,
    shiftPeriod,
    toDateInput
} from '../lib/periods';
import { useLeaderboardStore } from '../stores/leaderboard';
import { useSessionStore } from '../stores/session';
import { fakeJwt, jsonResponse, tokenResponse } from './helpers';

describe('periods', () => {
    it('runs weeks Monday to Sunday', () => {
        // Sunday 18 October 2026.
        const week = periodContaining('week', new Date(2026, 9, 18, 21, 30));
        expect(week.from).toEqual(new Date(2026, 9, 12));
        expect(week.to).toEqual(new Date(2026, 9, 19));
        expect(shiftPeriod(week, -1).from).toEqual(new Date(2026, 9, 5));
    });

    it('steps months across a year', () => {
        const january = periodContaining('month', new Date(2026, 0, 31));
        expect(january).toEqual({ kind: 'month', from: new Date(2026, 0, 1), to: new Date(2026, 1, 1) });
        expect(shiftPeriod(january, -1).from).toEqual(new Date(2025, 11, 1));
    });

    it('takes a custom range in either order, both days included, and steps by its length', () => {
        const range = customPeriod(new Date(2026, 9, 10), new Date(2026, 9, 1, 15));
        expect(range.from).toEqual(new Date(2026, 9, 1));
        expect(range.to).toEqual(new Date(2026, 9, 11));
        expect(periodDays(range)).toBe(10);
        expect(shiftPeriod(range, -1)).toEqual({
            kind: 'custom',
            from: new Date(2026, 8, 21),
            to: new Date(2026, 9, 1)
        });
    });

    it('knows when there is nothing later to show', () => {
        const now = new Date(2026, 9, 19, 12);
        expect(isCurrentOrLater(periodContaining('week', now), now)).toBe(true);
        expect(isCurrentOrLater(periodContaining('week', new Date(2026, 9, 11)), now)).toBe(false);
    });

    it('labels periods compactly', () => {
        const now = new Date(2026, 9, 19);
        expect(formatPeriod(periodContaining('month', now), now)).toBe('October 2026');
        expect(formatPeriod(periodContaining('week', now), now)).toBe('19 – 25 Oct');
        expect(formatPeriod(periodContaining('week', new Date(2026, 8, 30)), now)).toBe('28 Sep – 4 Oct');
        expect(formatPeriod(periodContaining('week', new Date(2026, 0, 1)), now)).toBe('29 Dec 2025 – 4 Jan 2026');
        expect(formatPeriod(customPeriod(new Date(2026, 9, 3), new Date(2026, 9, 3)), now)).toBe('3 Oct');
    });

    it('round-trips date inputs', () => {
        expect(toDateInput(new Date(2026, 0, 5))).toBe('2026-01-05');
        expect(fromDateInput('2026-01-05')).toEqual(new Date(2026, 0, 5));
        expect(fromDateInput('')).toBeNull();
    });
});

describe('parseLeaderboard', () => {
    it('reads entries and skips ones without a user', () => {
        expect(
            parseLeaderboard({
                entries: [
                    {
                        user_id: 'a',
                        username: 'Ada',
                        rank: 1,
                        distance_meters: 12000,
                        duration_seconds: 900,
                        avg_speed: 13.3,
                        top_speed: 25,
                        trip_count: 2
                    },
                    { username: 'nobody' },
                    { user_id: 'b', rank: 2 }
                ]
            })
        ).toEqual([
            {
                userId: 'a',
                name: 'Ada',
                rank: 1,
                distanceMeters: 12000,
                durationSeconds: 900,
                avgSpeed: 13.3,
                topSpeed: 25,
                tripCount: 2
            },
            {
                userId: 'b',
                name: 'b',
                rank: 2,
                distanceMeters: 0,
                durationSeconds: 0,
                avgSpeed: 0,
                topSpeed: 0,
                tripCount: 0
            }
        ]);
        expect(parseLeaderboard(null)).toEqual([]);
    });
});

describe('leaderboard view', () => {
    let fetchMock: ReturnType<typeof vi.fn>;

    function leaderboardCalls(): URL[] {
        return fetchMock.mock.calls
            .map(([url]) => new URL(String(url)))
            .filter((url) => url.pathname === '/api/v1/leaderboard');
    }

    beforeEach(async () => {
        localStorage.clear();
        setActivePinia(createPinia());
        fetchMock = vi.fn();
        vi.stubGlobal('fetch', fetchMock);
        fetchMock.mockResolvedValueOnce(
            jsonResponse(tokenResponse(fakeJwt({ sub: 'me', username: 'ada', scopes: { tracker: true } })))
        );
        await useSessionStore().login('ada', 'pw');
        fetchMock.mockImplementation(async () =>
            jsonResponse({
                entries: [
                    {
                        user_id: 'b',
                        username: 'Bo',
                        rank: 1,
                        distance_meters: 42000,
                        duration_seconds: 3600,
                        avg_speed: 11.67,
                        top_speed: 33.4,
                        trip_count: 3
                    },
                    {
                        user_id: 'me',
                        username: 'ada',
                        rank: 2,
                        distance_meters: 0,
                        duration_seconds: 0,
                        avg_speed: 0,
                        top_speed: 0,
                        trip_count: 0
                    }
                ]
            })
        );
    });

    afterEach(() => vi.unstubAllGlobals());

    it('loads the current week, ranks people and marks you', async () => {
        const board = useLeaderboardStore();
        board.open();
        const wrapper = mount(TravelLeaderboard, { props: { selfId: 'me' } });
        await vi.waitFor(() => expect(wrapper.findAll('[data-entry]')).toHaveLength(2));

        const [call] = leaderboardCalls();
        const week = periodContaining('week', new Date());
        expect(new Date(call.searchParams.get('from')!)).toEqual(week.from);
        expect(new Date(call.searchParams.get('to')!)).toEqual(week.to);

        const [first, second] = wrapper.findAll('[data-entry]');
        expect(first.text()).toContain('Bo');
        expect(first.text()).toContain('42 km');
        expect(first.text()).toContain('42 km/h avg');
        expect(first.text()).toContain('120 km/h top');
        expect(second.text()).toContain('ada (you)');
        expect(second.text()).toContain('No trips');
        // This week is still going: nothing later to step to.
        expect(wrapper.get('[data-next]').attributes('disabled')).toBeDefined();
    });

    it('switches to months and steps back', async () => {
        const board = useLeaderboardStore();
        board.open();
        const wrapper = mount(TravelLeaderboard, { props: { selfId: 'me' } });
        await wrapper.get('[data-kind="month"]').trigger('click');
        await wrapper.get('[data-previous]').trigger('click');
        await vi.waitFor(() => expect(leaderboardCalls()).toHaveLength(3));

        const last = leaderboardCalls()[2];
        const now = new Date();
        expect(new Date(last.searchParams.get('from')!)).toEqual(new Date(now.getFullYear(), now.getMonth() - 1, 1));
        expect(new Date(last.searchParams.get('to')!)).toEqual(new Date(now.getFullYear(), now.getMonth(), 1));
        await nextTick();
        expect(wrapper.get('[data-period]').text()).toBe(formatPeriod(board.period));
        expect(wrapper.get('[data-next]').attributes('disabled')).toBeUndefined();
    });

    it('asks for a picked range and refuses one that is too long', async () => {
        const board = useLeaderboardStore();
        board.open();
        const wrapper = mount(TravelLeaderboard, { props: { selfId: 'me' } });
        await wrapper.get('[data-kind="custom"]').trigger('click');
        await nextTick();

        await wrapper.get('[data-from]').setValue('2026-09-01');
        await wrapper.get('[data-to]').setValue('2026-09-14');
        await wrapper.get('[data-to]').trigger('change');
        await vi.waitFor(() =>
            expect(new Date(leaderboardCalls().at(-1)!.searchParams.get('to')!)).toEqual(new Date(2026, 8, 15))
        );
        expect(new Date(leaderboardCalls().at(-1)!.searchParams.get('from')!)).toEqual(new Date(2026, 8, 1));

        const before = leaderboardCalls().length;
        await wrapper.get('[data-from]').setValue('2024-01-01');
        await wrapper.get('[data-from]').trigger('change');
        expect(leaderboardCalls()).toHaveLength(before);
        expect(wrapper.get('[role="alert"]').text()).toContain('366 days');
    });
});
