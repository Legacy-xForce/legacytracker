import assert from "node:assert/strict";
import { test } from "node:test";

import ConnectionManager from "../src/services/connection-manager";
import {
  messageFor,
  redactedEntry,
  SharingRegistry,
} from "../src/services/sharing";

test("sharing is on unless the owner switched it off for that viewer", () => {
  const registry = new SharingRegistry();
  assert.equal(registry.isHidden("a", "b"), false);
  registry.set("a", "b", false);
  assert.equal(registry.isHidden("a", "b"), true);
  assert.equal(registry.isHidden("a", "c"), false);
  assert.equal(registry.isHidden("b", "a"), false, "it is one-directional");
});

test("re-enabling and repeating a change are harmless", () => {
  const registry = new SharingRegistry();
  registry.set("a", "b", false);
  registry.set("a", "b", false);
  assert.deepEqual(registry.hiddenFrom("a"), ["b"]);
  registry.set("a", "b", true);
  registry.set("a", "b", true);
  assert.equal(registry.isHidden("a", "b"), false);
  assert.deepEqual(registry.hiddenFrom("a"), []);
});

test("your own position is never hidden from you", () => {
  const registry = new SharingRegistry();
  registry.set("a", "a", false);
  assert.equal(registry.isHidden("a", "a"), false);
});

test("load replaces the registry with the stored rows", () => {
  const registry = new SharingRegistry();
  registry.set("x", "y", false);
  registry.load([{ ownerId: "a", viewerId: "b" }]);
  assert.equal(registry.isHidden("x", "y"), false);
  assert.equal(registry.isHidden("a", "b"), true);
});

test("a redacted entry carries no location or presence data", () => {
  assert.deepEqual(redactedEntry("a", "Ann"), {
    user_id: "a",
    username: "Ann",
    sharing: false,
  });
});

test("an update reaches everyone except the viewers it is hidden from", () => {
  const registry = new SharingRegistry();
  registry.set("a", "b", false);
  const sent: Record<string, string[]> = { a: [], b: [], c: [] };
  const manager = new ConnectionManager();
  for (const id of Object.keys(sent)) {
    manager.add(id, { send: (text: string) => sent[id].push(text), close() {} });
  }

  manager.broadcastEach(messageFor(registry, "a", { user_id: "a", latitude: 1 }));

  assert.equal(sent.a.length, 1);
  assert.equal(sent.b.length, 0);
  assert.equal(sent.c.length, 1);
});

test("sendTo reports whether the viewer was connected", () => {
  const manager = new ConnectionManager();
  const got: string[] = [];
  manager.add("b", { send: (t: string) => got.push(t), close() {} });
  assert.equal(manager.sendTo("b", { x: 1 }), true);
  assert.equal(manager.sendTo("zz", { x: 1 }), false);
  assert.deepEqual(got, ['{"x":1}']);
});
