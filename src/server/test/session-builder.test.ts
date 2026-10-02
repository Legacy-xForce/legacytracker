import assert from "node:assert/strict";
import { test } from "node:test";

import { buildSessions, type HistoryPoint } from "../src/services/session-builder";

const T0 = Date.parse("2026-10-01T08:00:00.000Z");

// ~111 m per 0.001° of latitude.
function point(
  minutes: number,
  northMeters: number,
  speed: number,
  source: string | null = "move",
): HistoryPoint {
  return {
    recordedAt: new Date(T0 + minutes * 60_000).toISOString(),
    latitude: 45 + northMeters / 111_195,
    longitude: 7,
    speed,
    heading: 0,
    source,
  };
}

test("trip markers delimit sessions even without a time gap", () => {
  const sessions = buildSessions([
    point(0, 0, 0, "trip_start"),
    point(1, 500, 12),
    point(2, 1000, 0, "trip_end"),
    point(4, 1000, 0, "trip_start"),
    point(5, 1600, 14),
    point(6, 2200, 0, "trip_end"),
  ]);
  assert.equal(sessions.length, 2);
  assert.equal(sessions[0].pointCount, 3);
  assert.equal(sessions[1].pointCount, 3);
});

test("a silent stop that ends where it started splits the session", () => {
  // Engine records nothing while parked: 12 minutes of silence, 20 m apart.
  const sessions = buildSessions([
    point(0, 0, 10),
    point(1, 600, 12),
    point(13, 620, 3),
    point(14, 1200, 13),
  ]);
  assert.equal(sessions.length, 2);
});

test("heartbeat and ping points never become part of a trip", () => {
  const sessions = buildSessions([
    point(0, 0, 0, "heartbeat"),
    point(1, 0, 0, "trip_start"),
    point(2, 700, 15),
    point(3, 1400, 0, "trip_end"),
    point(4, 1405, 0, "ping"),
  ]);
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].pointCount, 3);
});

test("average speed is distance over time, not a per-sample mean", () => {
  // Dense slow samples followed by one fast stretch: a sample mean would
  // badly understate the trip's speed.
  const sessions = buildSessions([
    point(0, 0, 2, "trip_start"),
    point(0.25, 30, 2),
    point(0.5, 60, 2),
    point(0.75, 90, 2),
    point(10, 6090, 0, "trip_end"),
  ]);
  assert.equal(sessions.length, 1);
  const s = sessions[0];
  assert.ok(Math.abs(s.avgSpeed - s.distanceMeters / s.durationSeconds) < 1e-9);
  assert.ok(s.avgSpeed > 9.5 && s.avgSpeed < 10.5);
});

test("parked GPS drift is not reported as a trip", () => {
  const sessions = buildSessions([
    point(0, 0, 0.3),
    point(1, 30, 0.5),
    point(2, 5, 0.4),
    point(3, 40, 0.2),
  ]);
  assert.equal(sessions.length, 0);
});
