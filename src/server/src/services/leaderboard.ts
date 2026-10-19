import { buildSessions, type HistoryPoint } from "./session-builder";

export interface TravelTotals {
  distanceMeters: number;
  /** Time spent on trips, not the length of the window. */
  durationSeconds: number;
  avgSpeed: number;
  topSpeed: number;
  tripCount: number;
}

export interface LeaderboardEntry extends TravelTotals {
  userId: string;
  name: string;
  rank: number;
}

/**
 * One person's travel over a window, from the same trips the history shows: a
 * phone sitting on a desk drifts a few hundred metres a day, and only the
 * session builder knows to leave that out.
 */
export function summarizeTravel(points: HistoryPoint[]): TravelTotals {
  const sessions = buildSessions(points);
  let distanceMeters = 0;
  let durationSeconds = 0;
  let topSpeed = 0;
  for (const session of sessions) {
    distanceMeters += session.distanceMeters;
    durationSeconds += session.durationSeconds;
    topSpeed = Math.max(topSpeed, session.topSpeed);
  }
  return {
    distanceMeters,
    durationSeconds,
    // Over the time actually moving, like a trip's own average.
    avgSpeed: durationSeconds > 0 ? distanceMeters / durationSeconds : 0,
    topSpeed,
    tripCount: sessions.length,
  };
}

/**
 * Orders people by distance, furthest first. Only people with at least one
 * trip are listed, plus `selfId` (the viewer should always find themselves).
 * Equal distances share a rank.
 */
export function rankLeaderboard(
  totals: { userId: string; name: string; totals: TravelTotals }[],
  selfId: string,
): LeaderboardEntry[] {
  const entries = totals
    .filter(({ userId, totals }) => totals.tripCount > 0 || userId === selfId)
    .map(({ userId, name, totals }) => ({ userId, name, ...totals }))
    .sort(
      (a, b) =>
        b.distanceMeters - a.distanceMeters || a.name.localeCompare(b.name),
    );

  let rank = 0;
  return entries.map((entry, index) => {
    if (
      index === 0 ||
      entry.distanceMeters !== entries[index - 1].distanceMeters
    ) {
      rank = index + 1;
    }
    return { ...entry, rank };
  });
}
