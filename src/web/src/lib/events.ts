import { config } from '../config';
import { formatClock, formatElapsed } from './format';

export interface Attendee {
    id: string;
    name: string;
    /** Legacy Calendar points this at Legacy Auth. */
    pictureUrl: string | null;
}

/** The pin colour of an event the calendar gave none, as in the app. */
export const EVENT_FALLBACK_COLOR = '#7c4dff';

/** An event from Legacy Calendar. `point` is where its free-text location resolved to, once it has. */
export interface CalendarEvent {
    id: string;
    title: string;
    /** Epoch ms. */
    startTime: number;
    endTime: number | null;
    color: string | null;
    location: string | null;
    /** The host plus everyone who accepted. */
    attendees: Attendee[];
    point: [number, number] | null;
}

/** "#rrggbb" or "#rgb" (leading # optional) as "#rrggbb"; null for anything else. */
export function parseHexColor(value: unknown): string | null {
    if (typeof value !== 'string') return null;
    let hex = value.trim().replace(/^#/, '');
    if (/^[0-9a-f]{3}$/i.test(hex)) hex = [...hex].map((c) => c + c).join('');
    return /^[0-9a-f]{6}$/i.test(hex) ? `#${hex.toLowerCase()}` : null;
}

/** Null when the event is unusable (no id, title or start time). */
export function parseEvent(raw: unknown): CalendarEvent | null {
    if (typeof raw !== 'object' || raw === null) return null;
    const json = raw as Record<string, unknown>;
    const start = Date.parse(String(json.startTime));
    if (json.id == null || typeof json.title !== 'string' || Number.isNaN(start)) return null;

    const attendees = new Map<string, Attendee>();
    const add = (user: unknown) => {
        if (typeof user !== 'object' || user === null) return;
        const { id, username, profilePictureUrl } = user as {
            id?: unknown;
            username?: unknown;
            profilePictureUrl?: unknown;
        };
        if (id == null || attendees.has(String(id))) return;
        attendees.set(String(id), {
            id: String(id),
            name: String(username ?? ''),
            pictureUrl: typeof profilePictureUrl === 'string' && profilePictureUrl !== '' ? profilePictureUrl : null
        });
    };
    add(json.host);
    if (Array.isArray(json.participants)) {
        for (const participant of json.participants) {
            if ((participant as { status?: unknown } | null)?.status === 'ACCEPTED') add(participant);
        }
    }

    const end = json.endTime == null ? NaN : Date.parse(String(json.endTime));
    const location = typeof json.location === 'string' ? json.location.trim() : '';
    return {
        id: String(json.id),
        title: json.title.trim() === '' ? 'Untitled event' : json.title.trim(),
        startTime: start,
        endTime: Number.isNaN(end) ? null : end,
        color: parseHexColor(json.color),
        location: location === '' ? null : location,
        attendees: [...attendees.values()],
        point: null
    };
}

/** The event's page in the Legacy Calendar web app. */
export function eventUrl(event: CalendarEvent): string {
    return `${config.calendarWebUrl}/event/${encodeURIComponent(event.id)}`;
}

/** When the event stops being worth showing: its end, or local midnight ending its start day if it has none. */
export function shownUntil(event: CalendarEvent): number {
    if (event.endTime !== null) return event.endTime;
    const start = new Date(event.startTime);
    return new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1).getTime();
}

export function isOver(event: CalendarEvent, now: number): boolean {
    return now >= shownUntil(event);
}

export function isRunning(event: CalendarEvent, now: number): boolean {
    return now >= event.startTime && !isOver(event, now);
}

/** "Starts in 2h 5m (18:30)" / "Ends in 40m", for the details popup. */
export function timing(event: CalendarEvent, now: number): string {
    if (isRunning(event, now)) {
        return event.endTime === null ? 'Happening now' : `Ends in ${formatElapsed(event.endTime - now)}`;
    }
    return `Starts in ${formatElapsed(event.startTime - now)} (${formatClock(event.startTime)})`;
}
