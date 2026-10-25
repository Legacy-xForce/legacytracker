import assert from "node:assert/strict";
import { test } from "node:test";

import {
  MapboxNotConfiguredError,
  MapboxTokenRequestError,
  MapboxTokenService,
} from "../src/services/mapbox-tokens";

const secret = "sk.secret-token-value";
const username = "legacy-tracker";
const now = Date.UTC(2026, 9, 25, 12, 0, 0);

function response(body: unknown, ok = true, status = 200): Response {
  return {
    ok,
    status,
    json: async () => body,
  } as Response;
}

function service(fetchImpl: typeof fetch, clock: () => number = () => now) {
  return new MapboxTokenService({
    secretToken: secret,
    username,
    ttlSeconds: 3300,
    refreshMarginSeconds: 300,
    fetch: fetchImpl,
    now: clock,
  });
}

test("the service refuses to mint until both credentials are configured", async () => {
  const mint = new MapboxTokenService({ fetch: async () => response({}) });
  assert.equal(mint.configured, false);
  await assert.rejects(() => mint.getForUser("user-1"), MapboxNotConfiguredError);
});

test("mints a scoped temporary token for the configured account", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const mint = service(async (url, init) => {
    calls.push({ url: String(url), init: init! });
    return response({
      token: "tk.abc",
      issued_at: new Date(now).toISOString(),
      expires: new Date(now + 3300_000).toISOString(),
      expires_in: 3300,
    });
  });

  assert.deepEqual(await mint.getForUser("user-1"), {
    token: "tk.abc",
    expiresAt: new Date(now + 3300_000).toISOString(),
  });

  assert.equal(calls.length, 1);
  assert.equal(
    calls[0].url,
    `https://api.mapbox.com/tokens/v2/${username}?access_token=${encodeURIComponent(secret)}`,
  );
  assert.equal(calls[0].init.method, "POST");
  assert.equal(
    (calls[0].init.headers as Record<string, string>)["Content-Type"],
    "application/json",
  );
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), {
    expires: new Date(now + 3300_000).toISOString(),
    scopes: ["styles:read", "fonts:read"],
  });
});

test("reuses a cached token per user until shortly before it expires", async () => {
  let clock = now;
  let calls = 0;
  const mint = service(
    async () => {
      calls++;
      return response({
        token: `tk.${calls}`,
        expires: new Date(clock + 3300_000).toISOString(),
      });
    },
    () => clock,
  );

  const first = await mint.getForUser("user-1");
  assert.equal((await mint.getForUser("user-1")).token, first.token);
  assert.equal(calls, 1);

  // Another user gets their own token.
  assert.equal((await mint.getForUser("user-2")).token, "tk.2");
  assert.equal(calls, 2);

  // Five minutes before expiry the token is renewed; the old one stays valid
  // at Mapbox while the app switches over.
  clock += 3300_000 - 300_000 + 1;
  assert.equal((await mint.getForUser("user-1")).token, "tk.3");
  assert.equal(calls, 3);
});

test("concurrent requests for one user share a single mint", async () => {
  let calls = 0;
  let release!: (value: Response) => void;
  const pending = new Promise<Response>((resolve) => (release = resolve));
  const mint = service(async () => {
    calls++;
    return pending;
  });

  const requests = [
    mint.getForUser("user-1"),
    mint.getForUser("user-1"),
    mint.getForUser("user-1"),
  ];
  release(
    response({
      token: "tk.shared",
      expires: new Date(now + 3300_000).toISOString(),
    }),
  );

  const results = await Promise.all(requests);
  assert.deepEqual(
    results.map((result) => result.token),
    ["tk.shared", "tk.shared", "tk.shared"],
  );
  assert.equal(calls, 1);
});

test("falls back to the requested lifetime when Mapbox omits one", async () => {
  const mint = service(async () => response({ token: "tk.no-expiry" }));
  assert.deepEqual(await mint.getForUser("user-1"), {
    token: "tk.no-expiry",
    expiresAt: new Date(now + 3300_000).toISOString(),
  });
});

test("caps requested lifetimes at Mapbox's one-hour limit", async () => {
  const calls: RequestInit[] = [];
  const mint = new MapboxTokenService({
    secretToken: secret,
    username,
    ttlSeconds: 7200,
    fetch: async (_url, init) => {
      calls.push(init!);
      return response({ token: "tk.capped" });
    },
    now: () => now,
  });

  await mint.getForUser("user-1");
  assert.equal(JSON.parse(String(calls[0].body)).expires, new Date(now + 3600_000).toISOString());
});

test("surfaces Mapbox failures without leaking the secret", async () => {
  const mint = service(async () => response({ message: "nope" }, false, 401));
  await assert.rejects(
    () => mint.getForUser("user-1"),
    (error: unknown) => {
      assert.ok(error instanceof MapboxTokenRequestError);
      assert.equal(error.status, 401);
      assert.match(error.message, /401/);
      assert.ok(!error.message.includes(secret));
      return true;
    },
  );
});

test("a network failure is reported without the secret-bearing URL", async () => {
  const mint = service(async () => {
    throw new Error(`getaddrinfo failed for https://api.mapbox.com?access_token=${secret}`);
  });
  await assert.rejects(
    () => mint.getForUser("user-1"),
    (error: unknown) => {
      assert.ok(error instanceof MapboxTokenRequestError);
      assert.equal(error.status, null);
      assert.ok(!error.message.includes(secret));
      return true;
    },
  );
});
