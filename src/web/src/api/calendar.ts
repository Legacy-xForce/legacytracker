import { config } from '../config';
import { parseEvent, type CalendarEvent } from '../lib/events';
import { useSessionStore } from '../stores/session';

/** `noAccess` means the calendar refused our token: the account has no calendar. */
export class CalendarError extends Error {
    constructor(
        message: string,
        readonly noAccess = false
    ) {
        super(message);
    }
}

/** Events overlapping `from`..`to`, read from Legacy Calendar with the tracker's own access token. */
export async function fetchEvents(from: Date, to: Date): Promise<CalendarEvent[]> {
    const token = await useSessionStore().getAccessToken();
    if (!token) throw new CalendarError('Not signed in.', true);

    const query = new URLSearchParams({ start: from.toISOString(), end: to.toISOString() });
    let response: Response;
    try {
        response = await fetch(`${config.calendarUrl}/events?${query}`, {
            headers: { authorization: `Bearer ${token}` }
        });
    } catch {
        throw new CalendarError('Unable to reach the calendar.');
    }
    if (response.status === 401 || response.status === 403) throw new CalendarError('No calendar access.', true);
    if (!response.ok) throw new CalendarError(`Calendar error (${response.status}).`);
    const body: unknown = await response.json().catch(() => null);
    if (!Array.isArray(body)) throw new CalendarError('Unexpected calendar response.');
    return body.map(parseEvent).filter((event): event is CalendarEvent => event !== null);
}
