import { describe, expect, it } from 'vitest';
import type { HistorySession } from '../api/history';
import { formatLongDay, formatMonth, formatTripDuration } from '../lib/format';
import { addMonths, startOfMonth, summarizeByDay } from '../stores/history';

function trip(start: Date, minutes: number, meters: number): HistorySession {
    return {
        startAt: start.getTime(),
        endAt: start.getTime() + minutes * 60_000,
        durationSeconds: minutes * 60,
        distanceMeters: meters,
        avgSpeed: 5,
        topSpeed: 10,
        pointCount: 10,
        points: []
    };
}

describe('summarizeByDay', () => {
    it('adds up each local day of the month, by the day trips started', () => {
        const october = new Date(2026, 9, 1);
        const days = summarizeByDay(
            [
                trip(new Date(2026, 9, 14, 8, 0), 20, 5000),
                trip(new Date(2026, 9, 14, 18, 30), 10, 1500),
                trip(new Date(2026, 9, 3, 23, 50), 30, 9000),
                // Another month: not counted.
                trip(new Date(2026, 8, 30, 12, 0), 5, 100)
            ],
            october
        );
        expect([...days.keys()].sort((a, b) => a - b)).toEqual([3, 14]);
        expect(days.get(14)).toEqual({ trips: 2, distanceMeters: 6500, durationSeconds: 1800 });
    });
});

describe('months', () => {
    it('steps a month at a time from its first day', () => {
        expect(startOfMonth(new Date(2026, 9, 14, 13))).toEqual(new Date(2026, 9, 1));
        expect(addMonths(new Date(2026, 0, 1), -1)).toEqual(new Date(2025, 11, 1));
    });
});

describe('history formatting', () => {
    it('names days and months like the app', () => {
        expect(formatLongDay(new Date(2026, 9, 14))).toBe('Wednesday, 14 October');
        expect(formatMonth(new Date(2026, 9, 14))).toBe('October 2026');
    });

    it('rounds trips to whole minutes, never under one', () => {
        expect(formatTripDuration(20)).toBe('1m');
        expect(formatTripDuration(12 * 60)).toBe('12m');
        expect(formatTripDuration(65 * 60)).toBe('1h 5m');
        expect(formatTripDuration(120 * 60)).toBe('2h');
    });
});
