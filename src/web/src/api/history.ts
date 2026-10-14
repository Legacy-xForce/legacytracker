import { ApiError, trackerFetch } from './tracker';
import type { ReplayPoint } from '../lib/replay';

/** The person switched off sharing with us, so there is nothing to show. */
export class NotSharingError extends ApiError {
    constructor() {
        super('This person is not sharing their location with you.', 403);
    }
}

export interface HistorySession {
    startAt: number;
    endAt: number;
    durationSeconds: number;
    distanceMeters: number;
    avgSpeed: number;
    topSpeed: number;
    pointCount: number;
    /** Only present when the points were requested. */
    points: ReplayPoint[];
}

function num(value: unknown): number {
    const parsed = typeof value === 'string' ? Number(value) : value;
    return typeof parsed === 'number' && Number.isFinite(parsed) ? parsed : 0;
}

function time(value: unknown): number {
    return typeof value === 'string' ? Date.parse(value) : NaN;
}

function parsePoint(raw: Record<string, unknown>): ReplayPoint | null {
    const recordedAt = time(raw.recorded_at);
    if (typeof raw.latitude !== 'number' || typeof raw.longitude !== 'number' || Number.isNaN(recordedAt)) return null;
    return {
        latitude: raw.latitude,
        longitude: raw.longitude,
        speed: num(raw.speed),
        heading: typeof raw.heading === 'number' ? raw.heading : null,
        recordedAt
    };
}

export function parseSessions(body: unknown): HistorySession[] {
    const sessions = (body as { sessions?: unknown } | null)?.sessions;
    if (!Array.isArray(sessions)) return [];
    const parsed: HistorySession[] = [];
    for (const raw of sessions as Record<string, unknown>[]) {
        const startAt = time(raw.start_at);
        const endAt = time(raw.end_at);
        if (Number.isNaN(startAt) || Number.isNaN(endAt)) continue;
        parsed.push({
            startAt,
            endAt,
            durationSeconds: num(raw.duration_seconds),
            distanceMeters: num(raw.distance_meters),
            avgSpeed: num(raw.avg_speed),
            topSpeed: num(raw.top_speed),
            pointCount: num(raw.point_count),
            points: Array.isArray(raw.points)
                ? (raw.points as Record<string, unknown>[])
                      .map(parsePoint)
                      .filter((point): point is ReplayPoint => point !== null)
                : []
        });
    }
    return parsed;
}

/**
 * A person's travel sessions between two instants. Without `withPoints` only the summaries come
 * back, which allows a much longer window.
 */
export async function fetchSessions(
    userId: string,
    from: Date,
    to: Date,
    withPoints: boolean
): Promise<HistorySession[]> {
    const query = new URLSearchParams({ user_id: userId, from: from.toISOString(), to: to.toISOString() });
    if (!withPoints) query.set('points', 'false');
    const response = await trackerFetch(`/api/v1/history?${query}`);
    if (response.status === 403) {
        const body = (await response.json().catch(() => null)) as { error?: unknown } | null;
        if (body?.error === 'not_sharing') throw new NotSharingError();
        throw new ApiError('Access denied.', 403);
    }
    if (!response.ok) throw new ApiError(`Tracker error (${response.status}).`, response.status);
    return parseSessions(await response.json());
}
