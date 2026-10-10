import assert from "node:assert/strict";
import { test } from "node:test";

import { hasTrackerScope } from "../src/services/tracker-scope";

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
