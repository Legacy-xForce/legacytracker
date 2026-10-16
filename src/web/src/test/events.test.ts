import { describe, expect, it } from 'vitest';
import { eventUrl, isOver, isRunning, parseEvent, parseHexColor, shownUntil, timing } from '../lib/events';

const raw = {
    id: 'e1',
    title: '  Barbecue ',
    startTime: '2026-06-10T16:00:00.000Z',
    endTime: '2026-06-10T20:00:00.000Z',
    color: '#ABC',
    location: ' Piazza Duomo, Milano ',
    host: { id: 'h', username: 'Host' },
    participants: [
        { id: 'a', username: 'Ada', status: 'ACCEPTED' },
        { id: 'b', username: 'Bob', status: 'DECLINED' },
        { id: 'h', username: 'Host', status: 'ACCEPTED' }
    ]
};

describe('parseEvent', () => {
    it('reads an event, counting the host and accepted guests once', () => {
        const event = parseEvent(raw)!;
        expect(event.title).toBe('Barbecue');
        expect(event.location).toBe('Piazza Duomo, Milano');
        expect(event.color).toBe('#aabbcc');
        expect(event.attendees.map((a) => a.name)).toEqual(['Host', 'Ada']);
    });

    it('rejects events without an id, title or valid start', () => {
        expect(parseEvent({ ...raw, id: null })).toBeNull();
        expect(parseEvent({ ...raw, title: 4 })).toBeNull();
        expect(parseEvent({ ...raw, startTime: 'nope' })).toBeNull();
        expect(parseEvent('x')).toBeNull();
    });

    it('treats blanks as missing', () => {
        const event = parseEvent({ ...raw, title: '  ', location: ' ', endTime: null, color: 'red' })!;
        expect(event.title).toBe('Untitled event');
        expect(event.location).toBeNull();
        expect(event.endTime).toBeNull();
        expect(event.color).toBeNull();
    });
});

describe('parseHexColor', () => {
    it('accepts 3 and 6 digit forms with or without #', () => {
        expect(parseHexColor('#FF0000')).toBe('#ff0000');
        expect(parseHexColor('0f0')).toBe('#00ff00');
        expect(parseHexColor('#12')).toBeNull();
        expect(parseHexColor(5)).toBeNull();
    });
});

describe('how long an event is shown', () => {
    it('lasts until its end', () => {
        const event = parseEvent(raw)!;
        expect(shownUntil(event)).toBe(event.endTime);
        expect(isOver(event, event.endTime! - 1)).toBe(false);
        expect(isOver(event, event.endTime!)).toBe(true);
    });

    it('without an end lasts until local midnight after its start day', () => {
        const event = parseEvent({ ...raw, endTime: null })!;
        const start = new Date(event.startTime);
        expect(shownUntil(event)).toBe(new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1).getTime());
    });

    it('is running between start and end', () => {
        const event = parseEvent(raw)!;
        expect(isRunning(event, event.startTime - 1)).toBe(false);
        expect(isRunning(event, event.startTime)).toBe(true);
        expect(isRunning(event, event.endTime!)).toBe(false);
    });
});

describe('timing', () => {
    it('counts down to the start, then to the end', () => {
        const event = parseEvent(raw)!;
        expect(timing(event, event.startTime - 90 * 60_000)).toMatch(/^Starts in 1h 30m/);
        expect(timing(event, event.endTime! - 40 * 60_000)).toBe('Ends in 40m');
    });
});

describe('eventUrl', () => {
    it('points at the event in Legacy Calendar', () => {
        expect(eventUrl(parseEvent({ ...raw, id: 135 })!)).toBe('https://legacy-calendar.pages.dev/event/135');
    });

    it('escapes the id', () => {
        expect(eventUrl(parseEvent({ ...raw, id: 'a/b' })!)).toBe('https://legacy-calendar.pages.dev/event/a%2Fb');
    });
});
