import assert from "node:assert/strict";
import { test } from "node:test";

import { hasTrackerScope, isForTracker } from "../src/services/tracker-scope";

test("a token granting the tracker scope is accepted", () => {
  assert.equal(hasTrackerScope({ scopes: { calendar: false, tracker: true } }), true);
});

test("a token without the tracker scope is refused", () => {
  assert.equal(hasTrackerScope({ scopes: { calendar: true, tracker: false } }), false);
  assert.equal(hasTrackerScope({ scopes: { calendar: true } }), false);
  assert.equal(hasTrackerScope({ scopes: {} }), false);
});

test("missing or malformed scopes are refused", () => {
  assert.equal(hasTrackerScope({}), false);
  assert.equal(hasTrackerScope({ scopes: null }), false);
  assert.equal(hasTrackerScope({ scopes: "tracker" }), false);
  assert.equal(hasTrackerScope({ scopes: ["tracker"] }), false);
  // Only a literal `true` grants access.
  assert.equal(hasTrackerScope({ scopes: { tracker: "true" } }), false);
});

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
