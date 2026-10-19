import { ApiError, trackerFetch } from './tracker';

export interface LeaderboardEntry {
    userId: string;
    name: string;
    /** Equal distances share a rank. */
    rank: number;
    distanceMeters: number;
    /** Time spent on trips. */
    durationSeconds: number;
    avgSpeed: number;
    topSpeed: number;
    tripCount: number;
}

function num(value: unknown): number {
    const parsed = typeof value === 'string' ? Number(value) : value;
    return typeof parsed === 'number' && Number.isFinite(parsed) ? parsed : 0;
}

export function parseLeaderboard(body: unknown): LeaderboardEntry[] {
    const entries = (body as { entries?: unknown } | null)?.entries;
    if (!Array.isArray(entries)) return [];
    const parsed: LeaderboardEntry[] = [];
    for (const raw of entries as Record<string, unknown>[]) {
        if (typeof raw.user_id !== 'string' || raw.user_id === '') continue;
        parsed.push({
            userId: raw.user_id,
            name: typeof raw.username === 'string' && raw.username !== '' ? raw.username : raw.user_id,
            rank: num(raw.rank),
            distanceMeters: num(raw.distance_meters),
            durationSeconds: num(raw.duration_seconds),
            avgSpeed: num(raw.avg_speed),
            topSpeed: num(raw.top_speed),
            tripCount: num(raw.trip_count)
        });
    }
    return parsed;
}

/** Who travelled furthest between two instants, furthest first. */
export async function fetchLeaderboard(from: Date, to: Date): Promise<LeaderboardEntry[]> {
    const query = new URLSearchParams({ from: from.toISOString(), to: to.toISOString() });
    const response = await trackerFetch(`/api/v1/leaderboard?${query}`);
    if (!response.ok) throw new ApiError(`Tracker error (${response.status}).`, response.status);
    return parseLeaderboard(await response.json());
}
