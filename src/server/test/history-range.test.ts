import assert from "node:assert/strict";
import { test } from "node:test";

import { parseHistoryRange } from "../src/services/history-range";

const DAY_MS = 24 * 60 * 60 * 1000;
const valid = { from: "2026-10-15T00:00:00.000Z", to: "2026-10-15T23:59:59.999Z" };

test("a from/to pair inside the limit is accepted", () => {
  const result = parseHistoryRange(valid, 30 * DAY_MS);
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.from.toISOString(), valid.from);
    assert.equal(result.to.toISOString(), valid.to);
  }
});

test("both ends are required, so an empty request never matches everything", () => {
  assert.equal(parseHistoryRange({}, 30 * DAY_MS).ok, false);
  assert.equal(parseHistoryRange({ from: valid.from }, 30 * DAY_MS).ok, false);
  assert.equal(parseHistoryRange({ to: valid.to }, 30 * DAY_MS).ok, false);
});

test("unparseable timestamps are refused", () => {
  assert.equal(parseHistoryRange({ from: "yesterday", to: valid.to }, 30 * DAY_MS).ok, false);
});

test("a reversed range is refused", () => {
  assert.equal(parseHistoryRange({ from: valid.to, to: valid.from }, 30 * DAY_MS).ok, false);
});

test("a window longer than the limit is refused", () => {
  const query = { from: "2026-09-01T00:00:00Z", to: "2026-10-15T00:00:00Z" };
  assert.equal(parseHistoryRange(query, 30 * DAY_MS).ok, false);
  assert.equal(parseHistoryRange(query, 60 * DAY_MS).ok, true);
});

test("a single instant is a valid range (a trip of one point)", () => {
  assert.equal(parseHistoryRange({ from: valid.from, to: valid.from }, 30 * DAY_MS).ok, true);
});
