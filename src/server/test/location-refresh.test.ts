import assert from "node:assert/strict";
import { test } from "node:test";

import { LocationRefreshCoordinator } from "../src/services/location-refresh";

function harness(send?: (userId: string) => Promise<void>) {
  const sent: string[] = [];
  const errors: unknown[] = [];
  const coordinator = new LocationRefreshCoordinator({
    timeoutMs: 25_000,
    send:
      send ??
      (async (userId) => {
        sent.push(userId);
      }),
    onError: (error) => errors.push(error),
  });
  return { coordinator, sent, errors };
}

test("an upload from the target completes the request", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { coordinator, sent } = harness();
  const outcome = coordinator.request("alice");
  assert.deepEqual(sent, ["alice"]);
  coordinator.noteUpload("alice");
  assert.equal(await outcome, "updated");
});

test("uploads from other users are ignored until the timeout", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { coordinator } = harness();
  const outcome = coordinator.request("alice");
  coordinator.noteUpload("bob");
  t.mock.timers.tick(24_999);
  coordinator.noteUpload("bob");
  t.mock.timers.tick(1);
  assert.equal(await outcome, "timeout");
});

test("concurrent requests for one user share a single push", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { coordinator, sent } = harness();
  const first = coordinator.request("alice");
  const second = coordinator.request("alice");
  assert.deepEqual(sent, ["alice"]);
  coordinator.noteUpload("alice");
  assert.deepEqual(await Promise.all([first, second]), ["updated", "updated"]);
});

test("a finished request does not count later uploads for the next one", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { coordinator, sent } = harness();
  const first = coordinator.request("alice");
  coordinator.noteUpload("alice");
  await first;

  // Nothing pending: this upload must not satisfy a request made afterwards.
  coordinator.noteUpload("alice");
  const second = coordinator.request("alice");
  assert.deepEqual(sent, ["alice", "alice"]);
  t.mock.timers.tick(25_000);
  assert.equal(await second, "timeout");
});

test("a push failure is reported but the wait still runs to the timeout", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const failure = new Error("fcm down");
  const { coordinator, errors } = harness(async () => {
    throw failure;
  });
  const outcome = coordinator.request("alice");
  await Promise.resolve();
  await Promise.resolve();
  assert.deepEqual(errors, [failure]);
  // The phone may still have heard it through another path.
  coordinator.noteUpload("alice");
  assert.equal(await outcome, "updated");
});
