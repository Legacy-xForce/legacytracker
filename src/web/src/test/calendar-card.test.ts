import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import CalendarCard from '../components/history/CalendarCard.vue';
import { formatDayKilometers } from '../lib/format';
import type { DaySummary } from '../stores/history';

function day(trips: number, distanceMeters: number): DaySummary {
    return { trips, distanceMeters, durationSeconds: trips * 1200 };
}

function mountCard(days: Map<number, DaySummary>) {
    return mount(CalendarCard, {
        props: {
            month: new Date(2026, 9, 1),
            days,
            loading: false,
            selectedDay: null,
            canGoBack: true,
            canGoForward: true
        }
    });
}

describe('CalendarCard', () => {
    it('shows a day its total km instead of a dot per trip', () => {
        const card = mountCard(new Map([[12, day(3, 12_400)]]));
        const cell = card.get('[data-has-trips]');
        expect(cell.text()).toBe('1212km');
        expect(cell.attributes('aria-label')).toContain('12km');
        // The dots were elements of their own inside the cell.
        expect(cell.element.querySelectorAll('span span')).toHaveLength(0);
    });

    it('labels only the days with trips', () => {
        const card = mountCard(new Map([[12, day(1, 800)]]));
        expect(card.findAll('[data-has-trips]')).toHaveLength(1);
        expect(card.get('[data-has-trips]').text()).toBe('121km');
    });
});

describe('formatDayKilometers', () => {
    it('rounds to whole km, and a day with trips never reads 0km', () => {
        expect(formatDayKilometers(300)).toBe('1km');
        expect(formatDayKilometers(5_120)).toBe('5km');
        expect(formatDayKilometers(12_400)).toBe('12km');
        expect(formatDayKilometers(43_400)).toBe('43km');
    });
});
