import assert from "node:assert/strict";
import { test } from "node:test";

import { advanceDwell, type Dwell, type DwellPoint } from "../src/services/dwell-tracker";

const T0 = Date.parse("2026-10-01T08:00:00.000Z");

// ~111 m per 0.001° of latitude.
function point(
  seconds: number,
  northMeters: number,
  speed = 0,
  source: string | null = "live",
): DwellPoint {
  return {
    recordedAt: new Date(T0 + seconds * 1000).toISOString(),
    latitude: 45 + northMeters / 111_195,
    longitude: 7,
    speed,
    source,
  };
}

function fold(points: DwellPoint[], start: Dwell | null = null): Dwell | null {
  return points.reduce<Dwell | null>((dwell, p) => advanceDwell(dwell, p), start);
}

const at = (seconds: number) => new Date(T0 + seconds * 1000).toISOString();

test("jittery fixes while parked keep the arrival time", () => {
  const dwell = fold([
    point(0, 0, 0, "trip_end"),
    point(60, 8),
    point(61, -5),
    point(62, 12, 0.4),
    point(600, 3, 0, "ping"),
  ]);
  assert.equal(dwell?.since, at(0));
  assert.equal(dwell?.lastAt, at(600));
});

test("driving away starts a new stay", () => {
  const dwell = fold([
    point(0, 0, 0, "trip_end"),
    point(300, 30, 9, "trip_start"),
    point(330, 400, 12, "move"),
    point(400, 900, 0, "trip_end"),
    point(460, 905),
  ]);
  assert.equal(dwell?.since, at(400));
});

test("a fast fix near the parking spot means the user is leaving", () => {
  const dwell = fold([point(0, 0), point(100, 20, 6)]);
  assert.equal(dwell?.since, at(100));
});

test("a heartbeat re-sending the parking spot pulls the arrival back", () => {
  // After a restart the stay was seeded from an on-demand ping; the engine's
  // heartbeat then re-sends the parking spot with its original time.
  const seeded: Dwell = {
    latitude: 45,
    longitude: 7,
    since: at(3600),
    lastAt: at(3600),
    after: at(-60),
  };
  const dwell = advanceDwell(seeded, point(0, 4, 0, "heartbeat"));
  assert.equal(dwell.since, at(0));
  assert.equal(dwell.lastAt, at(3600));
});

test("an older stay at the same place does not extend the current one", () => {
  const dwell = fold([
    point(0, 0, 0, "trip_end"), // home, yesterday
    point(1000, 50, 10, "trip_start"),
    point(1100, 2000, 0, "trip_end"),
    point(5000, 2000, 10, "trip_start"),
    point(5100, 0, 0, "trip_end"), // back home
  ]);
  assert.equal(dwell?.since, at(5100));
  // A late upload from the earlier stay at home arrives afterwards.
  const after = advanceDwell(dwell, point(10, 2));
  assert.equal(after.since, at(5100));
});

test("a late batch from elsewhere is ignored", () => {
  const dwell = fold([point(0, 0, 0, "trip_end"), point(600, 0)]);
  const after = advanceDwell(dwell, point(300, 5000, 0, "move"));
  assert.deepEqual(after, dwell);
});
