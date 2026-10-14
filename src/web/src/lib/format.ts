/** Elapsed time in its two most significant units: "42s", "12m 5s", "3h 20m", "42d 1h". */
export function formatElapsed(ms: number): string {
    const total = Math.max(0, Math.floor(ms / 1000));
    const days = Math.floor(total / 86400);
    const hours = Math.floor((total % 86400) / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;
    if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
    if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
    if (minutes > 0) return seconds > 0 ? `${minutes}m ${seconds}s` : `${minutes}m`;
    return `${seconds}s`;
}

/** Local wall-clock time, "08:05". */
export function formatClock(time: number | Date): string {
    const date = new Date(time);
    return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
}

export function formatDistance(meters: number): string {
    if (meters < 1000) return `${Math.round(meters)} m`;
    const km = meters / 1000;
    return `${km.toFixed(km < 10 ? 1 : 0)} km`;
}

export function escapeHtml(text: string): string {
    return text
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

export const MONTH_NAMES = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December'
];
const WEEKDAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/** "Wednesday, 14 October", as the app titles a day. */
export function formatLongDay(date: Date): string {
    return `${WEEKDAY_NAMES[date.getDay()]}, ${date.getDate()} ${MONTH_NAMES[date.getMonth()]}`;
}

/** "October 2026". */
export function formatMonth(date: Date): string {
    return `${MONTH_NAMES[date.getMonth()]} ${date.getFullYear()}`;
}

/** A trip's length in whole minutes: "1h 5m", "2h", "12m" (never under "1m"). */
export function formatTripDuration(seconds: number): string {
    const minutes = Math.max(1, Math.round(seconds / 60));
    const hours = Math.floor(minutes / 60);
    if (hours === 0) return `${minutes}m`;
    return minutes % 60 > 0 ? `${hours}h ${minutes % 60}m` : `${hours}h`;
}
