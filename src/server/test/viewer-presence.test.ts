import assert from "node:assert/strict";
import { test } from "node:test";

import { ViewerPresence } from "../src/services/viewer-presence";

function harness() {
  const changes: string[][] = [];
  const presence = new ViewerPresence({
    joinSettleMs: 500,
    leaveGraceMs: 3_000,
    onChange: (viewerIds) => changes.push(viewerIds),
  });
  return { presence, changes };
}

const users = (...ids: string[]) => new Set(ids);

test("a viewer appears once their map has settled", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { presence, changes } = harness();
  presence.update(users("a"));
  t.mock.timers.tick(499);
  assert.deepEqual(changes, []);
  t.mock.timers.tick(1);
  assert.deepEqual(changes, [["a"]]);
  assert.deepEqual(presence.viewerIds, ["a"]);
});

test("a map that closes before it settles never shows", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { presence, changes } = harness();
  presence.update(users("a"));
  t.mock.timers.tick(100);
  presence.update(users());
  t.mock.timers.tick(5_000);
  assert.deepEqual(changes, []);
});

test("a viewer who leaves goes after the grace period", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { presence, changes } = harness();
  presence.update(users("a", "b"));
  t.mock.timers.tick(500);
  presence.update(users("b"));
  t.mock.timers.tick(2_999);
  assert.deepEqual(presence.viewerIds, ["a", "b"]);
  t.mock.timers.tick(1);
  assert.deepEqual(presence.viewerIds, ["b"]);
  assert.deepEqual(changes.at(-1), ["b"]);
});

test("coming back within the grace period changes nothing", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { presence, changes } = harness();
  presence.update(users("a"));
  t.mock.timers.tick(500);
  // A reconnect: the old socket closes, a new one opens a moment later.
  presence.update(users());
  t.mock.timers.tick(1_000);
  presence.update(users("a"));
  t.mock.timers.tick(10_000);
  assert.deepEqual(changes, [["a"]]);
});

test("newcomers join the end of the row", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { presence } = harness();
  presence.update(users("b"));
  t.mock.timers.tick(500);
  presence.update(users("a", "b"));
  t.mock.timers.tick(500);
  assert.deepEqual(presence.viewerIds, ["b", "a"]);
});

test("repeated updates don't push a pending change back", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { presence } = harness();
  presence.update(users("a"));
  t.mock.timers.tick(300);
  presence.update(users("a"));
  t.mock.timers.tick(200);
  assert.deepEqual(presence.viewerIds, ["a"]);

  presence.update(users());
  t.mock.timers.tick(2_000);
  presence.update(users());
  t.mock.timers.tick(1_000);
  assert.deepEqual(presence.viewerIds, []);
});
