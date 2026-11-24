import assert from "node:assert/strict";
import { test } from "node:test";

import { isForTracker } from "../src/services/tracker-scope";

test("a token addressed to the tracker is for the tracker", () => {
  assert.equal(isForTracker({ aud: ["tracker"] }), true);
  assert.equal(isForTracker({ aud: ["calendar", "tracker"] }), true);
  assert.equal(isForTracker({ aud: "tracker" }), true);
});

test("a token for another app, or for none, is not", () => {
  assert.equal(isForTracker({ aud: ["calendar"] }), false);
  assert.equal(isForTracker({ aud: "calendar" }), false);
  assert.equal(isForTracker({ aud: [] }), false);
  assert.equal(isForTracker({}), false);
});
