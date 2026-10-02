import assert from "node:assert/strict";
import { test } from "node:test";

import { LiveController, type TrackingCommand } from "../src/services/live-controller";

function harness() {
  const sent: Array<[TrackingCommand, number]> = [];
  const controller = new LiveController({
    ttlSeconds: 600,
    renewIntervalMs: 240_000,
    offDebounceMs: 45_000,
    send: async (command, ttl) => {
      sent.push([command, ttl]);
    },
  });
  return { controller, sent };
}

test("first viewer turns live on immediately", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const { controller, sent } = harness();
  controller.update(1);
  assert.deepEqual(sent, [["live", 600]]);
  assert.equal(controller.ttlSeconds, 600);
  controller.update(0);
  t.mock.timers.tick(45_000);
});

test("tab flapping inside the debounce window sends nothing extra", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const { controller, sent } = harness();
  controller.update(1);
  controller.update(0);
  t.mock.timers.tick(20_000);
  controller.update(1);
  t.mock.timers.tick(30_000);
  assert.deepEqual(sent, [["live", 600]]);
  assert.equal(controller.isActive, true);
  controller.update(0);
  t.mock.timers.tick(45_000);
});

test("idle follows the debounce and stops renewals", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const { controller, sent } = harness();
  controller.update(2);
  t.mock.timers.tick(240_000);
  assert.deepEqual(sent, [["live", 600], ["live", 600]]);

  controller.update(0);
  t.mock.timers.tick(44_999);
  assert.equal(controller.isActive, true);
  t.mock.timers.tick(1);
  assert.equal(controller.isActive, false);
  assert.equal(controller.ttlSeconds, 0);
  assert.deepEqual(sent.at(-1), ["idle", 0]);

  const before = sent.length;
  t.mock.timers.tick(600_000);
  assert.equal(sent.length, before);
});
