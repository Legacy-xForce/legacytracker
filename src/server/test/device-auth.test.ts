import assert from "node:assert/strict";
import { after, test } from "node:test";

import { PGlite } from "@electric-sql/pglite";
import type { Pool } from "pg";

import {
  DEVICE_SCHEMA,
  DeviceAuth,
  type DeviceAuthOptions,
} from "../src/services/device-auth";

// One in-process Postgres for the file (booting one takes about a second);
// each test starts from empty tables.
const db = new PGlite();
after(() => db.close());

async function harness(options: DeviceAuthOptions = {}) {
  await db.exec(
    "DROP TABLE IF EXISTS device_token_history, devices, users CASCADE",
  );
  await db.exec("CREATE TABLE users (id text PRIMARY KEY, name text NOT NULL)");
  // Twice: startup runs it on every boot.
  for (const statement of [...DEVICE_SCHEMA, ...DEVICE_SCHEMA]) {
    await db.exec(statement);
  }
  await db.query("INSERT INTO users (id, name) VALUES ('alice', 'Alice')");

  // DeviceAuth only uses `query(text, values)` and `rows` / `rowCount`.
  const pool = {
    query: async (text: string, values?: unknown[]) => {
      const result = await db.query(text, values as never[]);
      return { rows: result.rows, rowCount: result.affectedRows ?? 0 };
    },
  } as unknown as Pool;

  const reused: { deviceId: string; userId: string }[] = [];
  const auth = new DeviceAuth(pool, {
    ...options,
    onReuse: (device) => reused.push(device),
  });
  const { deviceId, token } = await auth.register("alice", "android", null);
  return { auth, deviceId, token, reused };
}

const alice = (deviceId: string) => ({
  deviceId,
  userId: "alice",
  userName: "Alice",
});

test("a registered token verifies; an unknown one doesn't", async () => {
  const { auth, deviceId, token } = await harness();
  assert.deepEqual(await auth.verify(token), alice(deviceId));
  assert.equal(await auth.verify("not-a-token"), null);
});

test("a token younger than a day is not rotated", async () => {
  const { auth, token } = await harness();
  // No verify() first: that would serve the rotation check from the cache and
  // skip the token_issued_at guard we mean to exercise.
  assert.equal(await auth.rotateIfDue(token), null);
});

test("a due token is replaced, and the old one works until the new one is used", async () => {
  const { auth, deviceId, token, reused } = await harness({
    rotateAfterMs: 0,
  });
  await auth.verify(token);
  const next = await auth.rotateIfDue(token);
  assert.ok(next);
  assert.notEqual(next, token);

  // The response carrying `next` may not have arrived yet.
  assert.deepEqual(await auth.verify(token), alice(deviceId));
  assert.deepEqual(await auth.verify(next), alice(deviceId));
  assert.deepEqual(await auth.verify(next), alice(deviceId));
  assert.deepEqual(reused, []);
});

test("a copied old token rotates instead of revoking the device", async () => {
  const { auth, deviceId, token, reused } = await harness({
    rotateAfterMs: 0,
  });
  // Cached before the rotation: the cache must not keep accepting it.
  await auth.verify(token);
  const next = await auth.rotateIfDue(token);
  assert.ok(next);
  await auth.verify(next);

  // The copy comes back. Tracking is accepted and reported, not locked out.
  assert.deepEqual(await auth.verify(token, true), alice(deviceId));
  assert.deepEqual(reused, [{ deviceId, userId: "alice" }]);
  const reissued = await auth.rotateIfDue(token);
  assert.ok(reissued);
  assert.notEqual(reissued, next);

  // The copy is consumed, but the real phone's token and the fresh one still
  // work — it keeps uploading in the background without opening the app.
  assert.equal(await auth.verify(token), null);
  assert.deepEqual(await auth.verify(next), alice(deviceId));
  assert.deepEqual(await auth.verify(reissued), alice(deviceId));
});

test("a retired token is only accepted by the upload path", async () => {
  const { auth, deviceId, token } = await harness({ rotateAfterMs: 0 });
  await auth.verify(token);
  const next = await auth.rotateIfDue(token);
  assert.ok(next);
  await auth.verify(next); // first use of the replacement retires `token`

  // Credential-mutating routes use strict verification: a copied retired
  // token must not be able to revoke the device.
  assert.equal(await auth.verify(token), null);
  // The upload route opts in and immediately replaces it.
  assert.deepEqual(await auth.verify(token, true), alice(deviceId));
});

test("a lost replacement is re-issued, and the lost one is retired", async () => {
  const { auth, deviceId, token, reused } = await harness({
    rotateAfterMs: 0,
  });
  await auth.verify(token);
  const lost = await auth.rotateIfDue(token);
  assert.ok(lost);

  // The phone never saw `lost` and retries with its old token.
  assert.deepEqual(await auth.verify(token), alice(deviceId));
  const reissued = await auth.rotateIfDue(token);
  assert.ok(reissued);
  assert.notEqual(reissued, lost);
  assert.deepEqual(await auth.verify(reissued), alice(deviceId));
  assert.deepEqual(reused, []);

  // Someone presenting the token the phone never received holds a copy. It
  // is reported and consumed by a further rotation, while the phone's token
  // and the replacement keep working.
  assert.deepEqual(await auth.verify(lost, true), alice(deviceId));
  assert.deepEqual(reused, [{ deviceId, userId: "alice" }]);
  const rotated = await auth.rotateIfDue(lost);
  assert.ok(rotated);
  assert.notEqual(rotated, reissued);
  assert.equal(await auth.verify(lost), null);
  assert.deepEqual(await auth.verify(reissued), alice(deviceId));
});

test("revoking rejects both the current and the previous token", async () => {
  const { auth, deviceId, token } = await harness({ rotateAfterMs: 0 });
  await auth.verify(token);
  const next = await auth.rotateIfDue(token);
  assert.ok(next);

  assert.equal(await auth.revoke(deviceId, "alice"), true);
  assert.equal(await auth.verify(token), null);
  assert.equal(await auth.verify(next), null);
});

test("only one of two concurrent rotations of a token wins", async () => {
  const { auth, token } = await harness({ rotateAfterMs: 0 });
  await auth.verify(token);
  const results = await Promise.all([
    auth.rotateIfDue(token),
    auth.rotateIfDue(token),
  ]);
  assert.equal(results.filter((value) => value !== null).length, 1);
});

test("a reused token never affects another user's device", async () => {
  const { auth, deviceId, token, reused } = await harness({ rotateAfterMs: 0 });
  await db.query("INSERT INTO users (id, name) VALUES ('bob', 'Bob')");
  const bob = await auth.register("bob", "ios", null);

  await auth.verify(token);
  const next = await auth.rotateIfDue(token);
  assert.ok(next);
  await auth.verify(next);
  assert.deepEqual(await auth.verify(token, true), alice(deviceId));
  await auth.rotateIfDue(token);

  assert.deepEqual(await auth.verify(bob.token), {
    deviceId: bob.deviceId,
    userId: "bob",
    userName: "Bob",
  });
  assert.notEqual(bob.deviceId, deviceId);
  assert.deepEqual(reused, [{ deviceId, userId: "alice" }]);
});
