import assert from "node:assert/strict";
import { before, test } from "node:test";

import {
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  SignJWT,
  type JWTPayload,
  type KeyLike,
} from "jose";

import {
  ACCESS_REVOKED_EVENT,
  BACKCHANNEL_LOGOUT_EVENT,
  trackerScopeOf,
  verifyAccessToken,
  verifyLogoutToken,
  type VerifierConfig,
} from "../src/services/access-token";

const ISSUER = "https://auth.example.test";

let signingKey: KeyLike;
let otherKey: KeyLike;
let config: VerifierConfig;

before(async () => {
  const pair = await generateKeyPair("ES256");
  signingKey = pair.privateKey;
  otherKey = (await generateKeyPair("ES256")).privateKey;
  const jwk = { ...(await exportJWK(pair.publicKey)), kid: "k1", alg: "ES256" };
  config = {
    jwks: createLocalJWKSet({ keys: [jwk] }),
    issuer: ISSUER,
    allowedClients: ["tracker-spa", "tracker-mobile"],
  };
});

async function sign(
  claims: JWTPayload,
  { typ, key = signingKey }: { typ?: string; key?: KeyLike } = {},
): Promise<string> {
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "ES256", kid: "k1", ...(typ ? { typ } : {}) })
    .setIssuer(ISSUER)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(key);
}

// An access token as Legacy Auth's OpenID Provider issues it for the tracker.
function opToken(claims: JWTPayload = {}) {
  return sign(
    {
      sub: "user-1",
      aud: "tracker",
      client_id: "tracker-spa",
      scope: "tracker.read tracker.write",
      sid: "session-1",
      type: "access",
      scopes: { tracker: true, calendar: true },
      ...claims,
    },
    { typ: "at+jwt" },
  );
}

// A token from the old password login (`/auth/login`).
function legacyToken(claims: JWTPayload = {}) {
  return sign({
    sub: "user-1",
    aud: ["tracker", "calendar"],
    type: "access",
    scopes: { tracker: true, calendar: true },
    ...claims,
  });
}

function logoutToken(claims: JWTPayload = {}, typ = "logout+jwt") {
  return sign(
    {
      aud: "tracker-spa",
      sub: "user-1",
      sid: "session-1",
      jti: "j1",
      events: { [BACKCHANNEL_LOGOUT_EVENT]: {} },
      ...claims,
    },
    { typ },
  );
}

test("the OP scope string maps to read or write", () => {
  assert.equal(trackerScopeOf({ scope: "tracker.read tracker.write" }), "write");
  assert.equal(trackerScopeOf({ scope: "openid tracker.read" }), "read");
  assert.equal(trackerScopeOf({ scope: "calendar.read" }), null);
  assert.equal(trackerScopeOf({}), null);
});

test("an OP access token for the tracker is accepted", async () => {
  const result = await verifyAccessToken(await opToken(), config);
  assert.equal(result.ok, true);
  if (!result.ok) return;
  assert.equal(result.sub, "user-1");
  assert.equal(result.scope, "write");
  assert.equal(result.clientId, "tracker-spa");
  assert.equal(result.sid, "session-1");
});

test("an OP token with only tracker.read is read-only", async () => {
  const result = await verifyAccessToken(
    await opToken({ scope: "tracker.read" }),
    config,
  );
  assert.equal(result.ok && result.scope, "read");
});

test("an OP token without a tracker scope is forbidden", async () => {
  const result = await verifyAccessToken(
    await opToken({ scope: "openid" }),
    config,
  );
  assert.equal(result.ok, false);
  assert.equal(!result.ok && result.forbidden, true);
  // The OP never issues such a token, so it says nothing about API tokens.
  assert.equal(!result.ok && result.lostTrackerScope, undefined);
});

test("an OP token for the calendar is refused", async () => {
  const result = await verifyAccessToken(
    await opToken({ aud: "calendar", scope: "calendar.read" }),
    config,
  );
  assert.equal(result.ok, false);
  assert.equal(!result.ok && result.forbidden, undefined);
});

test("an OP token from another client is refused", async () => {
  for (const clientId of ["auth-console", "calendar-web", undefined]) {
    const result = await verifyAccessToken(
      await opToken({ client_id: clientId }),
      config,
    );
    assert.equal(result.ok, false, String(clientId));
  }
});

test("the legacy scopes claim doesn't decide for OP tokens", async () => {
  const result = await verifyAccessToken(
    await opToken({ scopes: { tracker: false }, type: undefined }),
    config,
  );
  assert.equal(result.ok, true);
});

test("a legacy token keeps working with full access", async () => {
  const result = await verifyAccessToken(await legacyToken(), config);
  assert.equal(result.ok, true);
  if (!result.ok) return;
  assert.equal(result.scope, "write");
  assert.equal(result.clientId, null);
  assert.equal(result.sid, null);
});

test("a legacy token without the tracker scope reports lost access", async () => {
  const result = await verifyAccessToken(
    await legacyToken({ scopes: { tracker: false }, aud: ["calendar"] }),
    config,
  );
  assert.equal(result.ok, false);
  if (result.ok) return;
  assert.equal(result.forbidden, true);
  assert.equal(result.lostTrackerScope, true);
  assert.equal(result.sub, "user-1");
});

test("a legacy token for another app is refused", async () => {
  const result = await verifyAccessToken(
    await legacyToken({ aud: ["calendar"] }),
    config,
  );
  assert.equal(result.ok, false);
  assert.equal(!result.ok && result.forbidden, undefined);
});

test("ID tokens, refresh tokens and logout tokens are not access tokens", async () => {
  const idToken = await sign({ sub: "user-1", aud: "tracker-spa", nonce: "n" });
  const refresh = await legacyToken({ type: "refresh" });
  for (const token of [idToken, refresh, await logoutToken()]) {
    assert.equal((await verifyAccessToken(token, config)).ok, false);
  }
});

test("a token signed with another key or issuer is refused", async () => {
  const forged = await sign(
    { sub: "user-1", aud: "tracker", client_id: "tracker-spa", scope: "tracker.write" },
    { typ: "at+jwt", key: otherKey },
  );
  assert.equal((await verifyAccessToken(forged, config)).ok, false);
  const result = await verifyAccessToken(await opToken(), {
    ...config,
    issuer: "https://elsewhere.test",
  });
  assert.equal(result.ok, false);
});

test("a valid logout token is accepted", async () => {
  const result = await verifyLogoutToken(await logoutToken(), config);
  assert.deepEqual(result, {
    ok: true,
    sub: "user-1",
    sid: "session-1",
    accessRevoked: false,
  });
});

test("a logout token can report that the account lost access", async () => {
  const result = await verifyLogoutToken(
    await logoutToken({
      sid: undefined,
      events: { [BACKCHANNEL_LOGOUT_EVENT]: {}, [ACCESS_REVOKED_EVENT]: {} },
    }),
    config,
  );
  assert.equal(result.ok && result.accessRevoked, true);
  assert.equal(result.ok && result.sid, null);
});

test("malformed logout tokens are refused", async () => {
  const cases: Array<[string, Promise<string>]> = [
    ["wrong typ", logoutToken({}, "JWT")],
    ["other audience", logoutToken({ aud: "calendar-web" })],
    ["no event", logoutToken({ events: {} })],
    ["events not an object", logoutToken({ events: BACKCHANNEL_LOGOUT_EVENT })],
    ["nonce", logoutToken({ nonce: "n" })],
    ["neither sub nor sid", logoutToken({ sub: undefined, sid: undefined })],
  ];
  for (const [name, token] of cases) {
    assert.equal((await verifyLogoutToken(await token, config)).ok, false, name);
  }
});

test("an old logout token is refused", async () => {
  const token = await new SignJWT({
    aud: "tracker-spa",
    sub: "user-1",
    events: { [BACKCHANNEL_LOGOUT_EVENT]: {} },
  })
    .setProtectedHeader({ alg: "ES256", kid: "k1", typ: "logout+jwt" })
    .setIssuer(ISSUER)
    .setIssuedAt(Math.floor(Date.now() / 1000) - 600)
    .sign(signingKey);
  assert.equal((await verifyLogoutToken(token, config)).ok, false);
});
