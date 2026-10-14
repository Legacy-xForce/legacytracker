import assert from "node:assert/strict";
import { test } from "node:test";

import {
  canModifyCheckpoint,
  haversineMeters,
  normalizeCheckpointName,
  resolveCheckpoint,
  validateCheckpointInput,
} from "../src/services/checkpoints";

const valid = { name: "Home", latitude: 45.5, longitude: 9.2, radius_m: 100 };

test("a complete checkpoint body is accepted and normalized", () => {
  const result = validateCheckpointInput({ ...valid, name: "  Home   Base " });
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.value, {
      name: "Home Base",
      latitude: 45.5,
      longitude: 9.2,
      radiusM: 100,
    });
  }
});

test("names are normalized so case-insensitive duplicates can be detected", () => {
  assert.equal(normalizeCheckpointName("\t Office \n Park "), "Office Park");
});

test("invalid names are refused", () => {
  assert.equal(validateCheckpointInput({ ...valid, name: "   " }).ok, false);
  assert.equal(validateCheckpointInput({ ...valid, name: 5 }).ok, false);
  assert.equal(
    validateCheckpointInput({ ...valid, name: "x".repeat(61) }).ok,
    false,
  );
  assert.equal(validateCheckpointInput({ ...valid, name: "x".repeat(60) }).ok, true);
});

test("coordinates must be in range", () => {
  assert.equal(validateCheckpointInput({ ...valid, latitude: 91 }).ok, false);
  assert.equal(validateCheckpointInput({ ...valid, longitude: -181 }).ok, false);
  assert.equal(validateCheckpointInput({ ...valid, latitude: "45" }).ok, false);
  assert.equal(validateCheckpointInput({ ...valid, latitude: NaN }).ok, false);
});

test("the radius is limited to 10-250 whole metres", () => {
  assert.equal(validateCheckpointInput({ ...valid, radius_m: 9 }).ok, false);
  assert.equal(validateCheckpointInput({ ...valid, radius_m: 10 }).ok, true);
  assert.equal(validateCheckpointInput({ ...valid, radius_m: 250 }).ok, true);
  assert.equal(validateCheckpointInput({ ...valid, radius_m: 251 }).ok, false);
  assert.equal(validateCheckpointInput({ ...valid, radius_m: 50.5 }).ok, false);
  assert.equal(validateCheckpointInput({ ...valid, radius_m: undefined }).ok, false);
});

test("a non-object body is refused", () => {
  assert.equal(validateCheckpointInput(null).ok, false);
  assert.equal(validateCheckpointInput("x").ok, false);
});

test("owners and admins may modify a checkpoint, other users may not", () => {
  assert.equal(canModifyCheckpoint("user", "u1", "u1"), true);
  assert.equal(canModifyCheckpoint("user", "u1", "u2"), false);
  assert.equal(canModifyCheckpoint("admin", "u1", "u2"), true);
  assert.equal(canModifyCheckpoint(null, "u1", "u2"), false);
  assert.equal(canModifyCheckpoint(undefined, "u1", "u1"), true);
});

test("haversine distance is roughly right", () => {
  // 0.001 degrees of latitude is ~111 m.
  const d = haversineMeters(45, 9, 45.001, 9);
  assert.ok(d > 110 && d < 112, `got ${d}`);
  assert.equal(haversineMeters(45, 9, 45, 9), 0);
});

const cp = (id: string, lat: number, lon: number, radiusM: number) => ({
  id,
  name: id,
  latitude: lat,
  longitude: lon,
  radiusM,
});

test("a point outside every checkpoint resolves to nothing", () => {
  assert.equal(resolveCheckpoint(45.01, 9, [cp("a", 45, 9, 100)]), null);
  assert.equal(resolveCheckpoint(45, 9, []), null);
});

test("a point inside a checkpoint resolves to it", () => {
  assert.equal(resolveCheckpoint(45.0005, 9, [cp("a", 45, 9, 100)])?.id, "a");
});

test("overlapping checkpoints resolve to the smallest radius", () => {
  const list = [cp("big", 45, 9, 250), cp("small", 45, 9, 50)];
  assert.equal(resolveCheckpoint(45, 9, list)?.id, "small");
});

test("equal radii resolve to the nearest center", () => {
  const list = [cp("far", 45.001, 9, 200), cp("near", 45, 9, 200)];
  assert.equal(resolveCheckpoint(45.0001, 9, list)?.id, "near");
});
