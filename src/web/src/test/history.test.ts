import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fetchSessions, NotSharingError, parseSessions } from '../api/history';
import { useSessionStore } from '../stores/session';
import { fakeJwt, jsonResponse, tokenResponse } from './helpers';

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(async () => {
    localStorage.clear();
    setActivePinia(createPinia());
    fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    fetchMock.mockResolvedValueOnce(
        jsonResponse(tokenResponse(fakeJwt({ sub: 'u', username: 'ada', scopes: { tracker: true } })))
    );
    await useSessionStore().login('ada', 'pw');
});

afterEach(() => vi.unstubAllGlobals());

describe('parseSessions', () => {
    it('reads summaries and points, dropping unusable ones', () => {
        const sessions = parseSessions({
            sessions: [
                {
                    start_at: '2026-06-10T10:00:00Z',
                    end_at: '2026-06-10T10:30:00Z',
                    duration_seconds: 1800,
                    distance_meters: 12000.5,
                    avg_speed: 6,
                    top_speed: 20,
                    point_count: 2,
                    points: [
                        { latitude: 1, longitude: 2, speed: 3, heading: 90, recorded_at: '2026-06-10T10:00:00Z' },
                        { latitude: 'x', longitude: 2, recorded_at: '2026-06-10T10:01:00Z' }
                    ]
                },
                { start_at: 'bad', end_at: 'bad' }
            ]
        });
        expect(sessions).toHaveLength(1);
        expect(sessions[0].distanceMeters).toBe(12000.5);
        expect(sessions[0].points).toEqual([
            { latitude: 1, longitude: 2, speed: 3, heading: 90, recordedAt: Date.parse('2026-06-10T10:00:00Z') }
        ]);
    });

    it('treats summary-only responses as having no points', () => {
        const [session] = parseSessions({
            sessions: [{ start_at: '2026-06-10T10:00:00Z', end_at: '2026-06-10T10:30:00Z' }]
        });
        expect(session.points).toEqual([]);
    });
});

describe('fetchSessions', () => {
    it('asks for summaries only unless points are wanted', async () => {
        fetchMock.mockImplementation(async () => jsonResponse({ sessions: [] }));
        await fetchSessions('u2', new Date(0), new Date(1000), false);
        await fetchSessions('u2', new Date(0), new Date(1000), true);
        expect(String(fetchMock.mock.calls[1][0])).toContain('points=false');
        expect(String(fetchMock.mock.calls[2][0])).not.toContain('points=');
    });

    it('reports a hidden person without locking the user out', async () => {
        fetchMock.mockResolvedValue(jsonResponse({ error: 'not_sharing' }, 403));
        await expect(fetchSessions('u2', new Date(0), new Date(1000), false)).rejects.toBeInstanceOf(NotSharingError);
        expect(useSessionStore().accessDenial).toBeNull();
    });

    it('still treats any other 403 as lost access', async () => {
        fetchMock.mockResolvedValue(jsonResponse({ error: 'Forbidden' }, 403));
        await expect(fetchSessions('u2', new Date(0), new Date(1000), false)).rejects.toThrow('Access denied.');
        expect(useSessionStore().accessDenial).toBe('missingScope');
    });
});
