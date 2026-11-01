/** A finite number from a number or a numeric string, else null. */
export function num(value: unknown): number | null {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string' && value.trim() !== '') {
        const parsed = Number(value);
        return Number.isFinite(parsed) ? parsed : null;
    }
    return null;
}

/** Like `num`, but 0 when there is nothing usable. */
export function numOrZero(value: unknown): number {
    return num(value) ?? 0;
}

/** Milliseconds since the epoch from an ISO string, else null. */
export function time(value: unknown): number | null {
    if (typeof value !== 'string') return null;
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
}
