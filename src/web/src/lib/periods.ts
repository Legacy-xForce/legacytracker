import { MONTH_NAMES } from './format';

export type PeriodKind = 'week' | 'month' | 'custom';

/** A span of whole local days: `from` is its first midnight, `to` the midnight after its last day. */
export interface Period {
    kind: PeriodKind;
    from: Date;
    to: Date;
}

/** The longest custom range the server answers, in days. */
export const MAX_PERIOD_DAYS = 366;

function day(date: Date, offset = 0): Date {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate() + offset);
}

/** The week (Monday to Sunday, like the calendar) or month that contains `date`. */
export function periodContaining(kind: 'week' | 'month', date: Date): Period {
    if (kind === 'month') {
        return {
            kind,
            from: new Date(date.getFullYear(), date.getMonth(), 1),
            to: new Date(date.getFullYear(), date.getMonth() + 1, 1)
        };
    }
    const from = day(date, -((date.getDay() + 6) % 7));
    return { kind, from, to: day(from, 7) };
}

/** The previous (-1) or next (+1) week or month. A custom range moves by its own length. */
export function shiftPeriod(period: Period, delta: number): Period {
    if (period.kind === 'month') {
        return periodContaining('month', new Date(period.from.getFullYear(), period.from.getMonth() + delta, 1));
    }
    if (period.kind === 'week') return periodContaining('week', day(period.from, 7 * delta));
    const days = Math.round((period.to.getTime() - period.from.getTime()) / 86_400_000);
    return { kind: 'custom', from: day(period.from, days * delta), to: day(period.to, days * delta) };
}

/** From the first to the last day, both included, in either order. */
export function customPeriod(first: Date, last: Date): Period {
    const [a, b] = first <= last ? [first, last] : [last, first];
    return { kind: 'custom', from: day(a), to: day(b, 1) };
}

export function periodDays(period: Period): number {
    return Math.round((period.to.getTime() - period.from.getTime()) / 86_400_000);
}

/** Whether the period is still going on (or hasn't started): there is nothing later to step to. */
export function isCurrentOrLater(period: Period, now = new Date()): boolean {
    return period.to.getTime() > now.getTime();
}

function short(date: Date, withYear: boolean): string {
    const label = `${date.getDate()} ${MONTH_NAMES[date.getMonth()].slice(0, 3)}`;
    return withYear ? `${label} ${date.getFullYear()}` : label;
}

/** "October 2026", "12 – 18 Oct", "28 Dec 2025 – 3 Jan 2026". */
export function formatPeriod(period: Period, now = new Date()): string {
    if (period.kind === 'month') return `${MONTH_NAMES[period.from.getMonth()]} ${period.from.getFullYear()}`;
    const last = day(period.to, -1);
    const sameYear = period.from.getFullYear() === last.getFullYear();
    const withYear = !sameYear || last.getFullYear() !== now.getFullYear();
    if (period.from.getTime() === last.getTime()) return short(last, withYear);
    if (sameYear && period.from.getMonth() === last.getMonth()) {
        return `${period.from.getDate()} – ${short(last, withYear)}`;
    }
    return `${short(period.from, !sameYear)} – ${short(last, withYear)}`;
}

/** `yyyy-mm-dd` for a date input. */
export function toDateInput(date: Date): string {
    const pad = (n: number) => String(n).padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

/** A date input's value as local midnight, or null when empty or malformed. */
export function fromDateInput(value: string): Date | null {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
    if (!match) return null;
    const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
    return Number.isNaN(date.getTime()) ? null : date;
}
