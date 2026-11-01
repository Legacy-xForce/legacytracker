import { strict as assert } from "node:assert";
import test from "node:test";
import { haversineMeters } from "../src/services/geo";

test("haversine distance is roughly right", () => {
  // 0.001 degrees of latitude is ~111 m.
  const d = haversineMeters(
    { latitude: 45, longitude: 9 },
    { latitude: 45.001, longitude: 9 },
  );
  assert.ok(d > 110 && d < 112, `got ${d}`);
  const p = { latitude: 45, longitude: 9 };
  assert.equal(haversineMeters(p, p), 0);
});
