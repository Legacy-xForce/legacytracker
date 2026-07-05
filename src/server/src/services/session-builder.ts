const SESSION_GAP_MINUTES = 15;
const STOP_RADIUS_METERS = 75;
const STOP_MIN_MINUTES = 10;
const MIN_SESSION_POINTS = 2;
const MIN_SESSION_DISTANCE_METERS = 50;
// GPS speed readings below walking pace are dominated by positional drift
// while parked, not real movement, even when accumulated "distance" clears
// MIN_SESSION_DISTANCE_METERS.
const MIN_SESSION_TOP_SPEED = 2.0;

export interface HistoryPoint {
  recordedAt: string;
  latitude: number;
  longitude: number;
  speed: number;
  heading: number | null;
}

export interface LocationSession {
  startAt: string;
  endAt: string;
  durationSeconds: number;
  distanceMeters: number;
  avgSpeed: number;
  topSpeed: number;
  pointCount: number;
  points: HistoryPoint[];
}

function haversineMeters(a: HistoryPoint, b: HistoryPoint): number {
  const R = 6371000;
  const lat1 = (a.latitude * Math.PI) / 180;
  const lat2 = (b.latitude * Math.PI) / 180;
  const dLat = ((b.latitude - a.latitude) * Math.PI) / 180;
  const dLon = ((b.longitude - a.longitude) * Math.PI) / 180;

  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

function summarize(points: HistoryPoint[]): LocationSession | null {
  if (points.length < MIN_SESSION_POINTS) {
    return null;
  }

  let distanceMeters = 0;
  let topSpeed = 0;
  let speedSum = 0;
  for (let i = 0; i < points.length; i += 1) {
    speedSum += points[i].speed;
    topSpeed = Math.max(topSpeed, points[i].speed);
    if (i > 0) {
      distanceMeters += haversineMeters(points[i - 1], points[i]);
    }
  }

  if (distanceMeters < MIN_SESSION_DISTANCE_METERS || topSpeed < MIN_SESSION_TOP_SPEED) {
    return null;
  }

  const startAt = points[0].recordedAt;
  const endAt = points[points.length - 1].recordedAt;
  const durationSeconds = Math.max(
    0,
    (new Date(endAt).getTime() - new Date(startAt).getTime()) / 1000,
  );

  return {
    startAt,
    endAt,
    durationSeconds,
    distanceMeters,
    avgSpeed: speedSum / points.length,
    topSpeed,
    pointCount: points.length,
    points,
  };
}

/**
 * Groups time-ordered points into movement sessions, splitting on long gaps
 * (tracking paused) or a sustained stop (staying within STOP_RADIUS_METERS of
 * an anchor for at least STOP_MIN_MINUTES).
 */
export function buildSessions(points: HistoryPoint[]): LocationSession[] {
  const sessions: LocationSession[] = [];
  let current: HistoryPoint[] = [];
  let stopAnchor: HistoryPoint | null = null;
  let stopStartIndex = -1;

  const flush = (): void => {
    const session = summarize(current);
    if (session) {
      sessions.push(session);
    }
    current = [];
    stopAnchor = null;
    stopStartIndex = -1;
  };

  for (const point of points) {
    if (current.length === 0) {
      current.push(point);
      continue;
    }

    const previous = current[current.length - 1];
    const gapMinutes =
      (new Date(point.recordedAt).getTime() - new Date(previous.recordedAt).getTime()) / 60000;

    if (gapMinutes > SESSION_GAP_MINUTES) {
      flush();
      current.push(point);
      continue;
    }

    if (stopAnchor === null) {
      stopAnchor = previous;
      stopStartIndex = current.length - 1;
    }

    if (haversineMeters(stopAnchor, point) > STOP_RADIUS_METERS) {
      // Left the stop cluster: if it lasted long enough, end the session here.
      const stopDurationMinutes =
        (new Date(previous.recordedAt).getTime() - new Date(stopAnchor.recordedAt).getTime()) /
        60000;
      if (stopDurationMinutes >= STOP_MIN_MINUTES) {
        const sessionPoints = current.slice(0, stopStartIndex + 1);
        const session = summarize(sessionPoints);
        if (session) {
          sessions.push(session);
        }
        // Discard the intermediate stationary points; resume the next
        // session from the departure point (the stop anchor) onward.
        current = [stopAnchor];
      }
      stopAnchor = null;
      stopStartIndex = -1;
    }

    current.push(point);
  }

  flush();

  return sessions;
}
