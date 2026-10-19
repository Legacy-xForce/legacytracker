import assert from "node:assert/strict";
import { test } from "node:test";

import {
  rankLeaderboard,
  summarizeTravel,
  type TravelTotals,
} from "../src/services/leaderboard";
import type { HistoryPoint } from "../src/services/session-builder";

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
    heading: null,
    source,
  };
}

function totals(distanceMeters: number, tripCount = 1): TravelTotals {
  return {
    distanceMeters,
    durationSeconds: 600,
    avgSpeed: distanceMeters / 600,
    topSpeed: 10,
    tripCount,
  };
}

test("sums every trip and keeps the fastest reading", () => {
  const travel = summarizeTravel([
    point(0, 0, 0, "trip_start"),
    point(5, 3000, 15),
    point(10, 6000, 0, "trip_end"),
    point(60, 6000, 0, "trip_start"),
    point(65, 9000, 25),
    point(70, 12000, 0, "trip_end"),
  ]);
  assert.equal(travel.tripCount, 2);
  assert.ok(Math.abs(travel.distanceMeters - 12000) < 1);
  assert.equal(travel.durationSeconds, 20 * 60);
  assert.equal(travel.topSpeed, 25);
  // Over the time moving, not the hour between the trips.
  assert.ok(Math.abs(travel.avgSpeed - 10) < 0.01);
});

test("GPS drift while parked is not travel", () => {
  // A phone on a desk: points wobbling around the same spot, all slow.
  const travel = summarizeTravel([
    point(0, 0, 0.3),
    point(1, 40, 0.5),
    point(2, 0, 0.4),
    point(3, 40, 0.2),
    point(4, 0, 0.6),
  ]);
  assert.deepEqual(travel, {
    distanceMeters: 0,
    durationSeconds: 0,
    avgSpeed: 0,
    topSpeed: 0,
    tripCount: 0,
  });
});

test("ranks furthest first and drops people who didn't move", () => {
  const ranked = rankLeaderboard(
    [
      { userId: "a", name: "Ada", totals: totals(5000) },
      { userId: "b", name: "Bo", totals: totals(0, 0) },
      { userId: "c", name: "Cy", totals: totals(12000) },
    ],
    "z",
  );
  assert.deepEqual(
    ranked.map((e) => [e.userId, e.rank]),
    [
      ["c", 1],
      ["a", 2],
    ],
  );
});

test("the viewer is listed even without a trip", () => {
  const ranked = rankLeaderboard(
    [
      { userId: "me", name: "Me", totals: totals(0, 0) },
      { userId: "a", name: "Ada", totals: totals(5000) },
    ],
    "me",
  );
  assert.deepEqual(
    ranked.map((e) => [e.userId, e.rank]),
    [
      ["a", 1],
      ["me", 2],
    ],
  );
});

test("equal distances share a rank, ordered by name", () => {
  const ranked = rankLeaderboard(
    [
      { userId: "b", name: "Bo", totals: totals(3000) },
      { userId: "a", name: "Ada", totals: totals(3000) },
      { userId: "c", name: "Cy", totals: totals(1000) },
    ],
    "z",
  );
  assert.deepEqual(
    ranked.map((e) => [e.name, e.rank]),
    [
      ["Ada", 1],
      ["Bo", 1],
      ["Cy", 3],
    ],
  );
});
