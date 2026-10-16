import assert from "node:assert/strict";
import { test } from "node:test";

import { parseTrackingIssues } from "../src/services/tracking-issues";

test("a report is kept, de-duplicated and put in a stable order", () => {
  assert.deepEqual(
    parseTrackingIssues([
      "battery_optimization",
      "location_services_off",
      "battery_optimization",
    ]),
    ["location_services_off", "battery_optimization"],
  );
});

test("an empty report means nothing is wrong, not 'unknown'", () => {
  assert.deepEqual(parseTrackingIssues([]), []);
});

test("a missing or malformed field means the device didn't say", () => {
  assert.equal(parseTrackingIssues(undefined), null);
  assert.equal(parseTrackingIssues(null), null);
  assert.equal(parseTrackingIssues("battery_optimization"), null);
  assert.equal(parseTrackingIssues({ 0: "battery_optimization" }), null);
});

test("unknown codes and non-strings are dropped", () => {
  assert.deepEqual(
    parseTrackingIssues(["wifi_off", 3, null, "background_location"]),
    ["background_location"],
  );
  assert.deepEqual(parseTrackingIssues(["wifi_off"]), []);
});
