/**
 * "Here since": when a user arrived where they are now, for the app's
 * "Here for" counter.
 *
 * The newest point can't answer that on its own. While someone watches the
 * map, devices stream a fresh fix every few seconds even when parked (GPS
 * jitter makes each one a slightly different position), and an on-demand
 * ping stores a brand-new timestamp at the same parking spot — so "now minus
 * the newest point" keeps snapping back to zero. A stay instead lasts for as
 * long as points keep landing within DWELL_RADIUS_METERS of where it began.
 */

export const DWELL_RADIUS_METERS = 100;

// Faster than this (m/s) is travelling, not GPS drift around a parked spot.
export const DWELL_MAX_SPEED = 2.0;

// Recorded trip points: the device itself decided it was on the move.
export const TRIP_SOURCES: ReadonlySet<string> = new Set(["move", "trip_start"]);

export interface DwellPoint {
  latitude: number;
  longitude: number;
  speed: number;
  recordedAt: string;
  source?: string | null;
}

export interface Dwell {
  latitude: number;
  longitude: number;
  /** When the stay began. */
  since: string;
  /** Newest point seen during the stay. */
  lastAt: string;
  /** Last time the user was seen somewhere else — the stay began after it. */
  after: string | null;
}

function haversineMeters(
  a: { latitude: number; longitude: number },
  b: { latitude: number; longitude: number },
): number {
  const R = 6371000;
  const lat1 = (a.latitude * Math.PI) / 180;
  const lat2 = (b.latitude * Math.PI) / 180;
  const dLat = ((b.latitude - a.latitude) * Math.PI) / 180;
  const dLon = ((b.longitude - a.longitude) * Math.PI) / 180;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

export function isTravellingPoint(point: DwellPoint): boolean {
  return TRIP_SOURCES.has(point.source ?? "") || point.speed >= DWELL_MAX_SPEED;
}

/**
 * Folds one point into the current stay. ISO-8601 UTC timestamps compare
 * correctly as strings.
 */
export function advanceDwell(
  current: Dwell | null | undefined,
  point: DwellPoint,
): Dwell {
  if (
    current &&
    !isTravellingPoint(point) &&
    haversineMeters(current, point) <= DWELL_RADIUS_METERS
  ) {
    // Still here. A heartbeat re-sends the parking spot with its original,
    // earlier time — that's a better arrival estimate than a later ping, as
    // long as it isn't from before the user last left.
    const refinesSince =
      point.recordedAt < current.since &&
      (current.after === null || point.recordedAt > current.after);
    return {
      ...current,
      since: refinesSince ? point.recordedAt : current.since,
      lastAt: point.recordedAt > current.lastAt ? point.recordedAt : current.lastAt,
    };
  }

  // A late batch from somewhere else doesn't move the user back in time.
  if (current && point.recordedAt < current.lastAt) {
    return current;
  }

  return {
    latitude: point.latitude,
    longitude: point.longitude,
    since: point.recordedAt,
    lastAt: point.recordedAt,
    after: current ? current.lastAt : null,
  };
}

/**
 * Rebuilds a user's current stay from stored history (after a restart, or
 * the first time the user is seen): the oldest point after the newest one
 * that was travelling or outside the radius of the newest point. Walks the
 * (user_id, recorded_at DESC) index backwards and stops at the first match.
 *
 * $1 user id, $2 DWELL_MAX_SPEED, $3 DWELL_RADIUS_METERS, $4 TRIP_SOURCES.
 */
export const DWELL_SEED_SQL = `
  SELECT ST_Y(l.location::geometry) AS latitude,
         ST_X(l.location::geometry) AS longitude,
         l.recorded_at AS last_at,
         away.recorded_at AS away_at,
         (SELECT min(h.recorded_at)
            FROM location_history h
           WHERE h.user_id = $1
             AND h.recorded_at > COALESCE(away.recorded_at, '-infinity'::timestamptz)
         ) AS since
    FROM (SELECT location, recorded_at
            FROM location_history
           WHERE user_id = $1
           ORDER BY recorded_at DESC
           LIMIT 1) l
    LEFT JOIN LATERAL (
      SELECT a.recorded_at
        FROM location_history a
       WHERE a.user_id = $1
         AND (a.source = ANY($4::text[])
              OR a.speed >= $2
              OR NOT ST_DWithin(a.location, l.location, $3))
       ORDER BY a.recorded_at DESC
       LIMIT 1
    ) away ON true`;

export interface DwellSeedRow {
  latitude: number;
  longitude: number;
  last_at: Date;
  away_at: Date | null;
  since: Date | null;
}

export function dwellFromSeedRow(row: DwellSeedRow): Dwell {
  const lastAt = new Date(row.last_at).toISOString();
  return {
    latitude: Number(row.latitude),
    longitude: Number(row.longitude),
    // No stored point after the last "away" one means the newest point is
    // itself travelling: the stay (if any) starts with it.
    since: row.since ? new Date(row.since).toISOString() : lastAt,
    lastAt,
    after: row.away_at ? new Date(row.away_at).toISOString() : null,
  };
}
