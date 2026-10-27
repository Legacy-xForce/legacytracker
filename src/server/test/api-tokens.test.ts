import assert from "node:assert/strict";
import { test } from "node:test";

import {
  apiTokenHint,
  generateApiToken,
  hashApiToken,
  isAllowedForScope,
  isApiTokenId,
  isApiTokenShape,
  MAX_API_TOKEN_NAME_LENGTH,
  validateApiTokenInput,
} from "../src/services/api-tokens";

test("generated tokens carry the prefix and a uuid", () => {
  const token = generateApiToken();
  assert.match(
    token,
    /^legacy-tracker-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
  );
  assert.notEqual(generateApiToken(), token);
  assert.equal(isApiTokenShape(token), true);
});

test("the hint shows only the ends of the secret", () => {
  const token = "legacy-tracker-01a15968-64aa-707d-8904-a6a408611289";
  assert.equal(apiTokenHint(token), "legacy-tracker-01a1…1289");
});

test("hashes are stable and differ per token", () => {
  const token = "legacy-tracker-01a15968-64aa-707d-8904-a6a408611289";
  assert.equal(hashApiToken(token), hashApiToken(token));
  assert.notEqual(hashApiToken(token), hashApiToken(generateApiToken()));
  assert.match(hashApiToken(token), /^[0-9a-f]{64}$/);
});

test("values that can't be tokens are rejected before a lookup", () => {
  assert.equal(isApiTokenShape("legacy-calendar-01a15968-64aa"), false);
  assert.equal(isApiTokenShape("legacy-tracker-"), false);
  assert.equal(isApiTokenShape("legacy-tracker-short"), false);
  assert.equal(isApiTokenShape("legacy-tracker-01a15968 64aa"), false);
  assert.equal(isApiTokenShape(`legacy-tracker-${"a".repeat(129)}`), false);
  assert.equal(isApiTokenShape("Bearer eyJhbGciOi"), false);
});

test("token ids must be uuids", () => {
  assert.equal(isApiTokenId("0e7a3c3e-2f7b-4f63-9c55-0bb0a4f3c1d2"), true);
  assert.equal(isApiTokenId("1"), false);
  assert.equal(isApiTokenId("0e7a3c3e-2f7b-4f63-9c55-0bb0a4f3c1d2x"), false);
});

test("creating a token needs a read or write scope", () => {
  assert.deepEqual(validateApiTokenInput({ scope: "read", name: " Home " }), {
    ok: true,
    value: { name: "Home", scope: "read" },
  });
  assert.deepEqual(validateApiTokenInput({ scope: "write" }), {
    ok: true,
    value: { name: "API token", scope: "write" },
  });
  assert.equal(validateApiTokenInput({ scope: "admin" }).ok, false);
  assert.equal(validateApiTokenInput({}).ok, false);
  assert.equal(validateApiTokenInput(null).ok, false);
  assert.equal(validateApiTokenInput({ scope: "read", name: 42 }).ok, false);
  assert.equal(
    validateApiTokenInput({
      scope: "read",
      name: "x".repeat(MAX_API_TOKEN_NAME_LENGTH + 1),
    }).ok,
    false,
  );
});

test("read tokens may only read, plus open the stream", () => {
  assert.equal(isAllowedForScope("read", "GET", "/api/v1/history"), true);
  assert.equal(isAllowedForScope("read", "HEAD", "/api/v1/history"), true);
  assert.equal(
    isAllowedForScope("read", "POST", "/api/v1/streams/ticket"),
    true,
  );
  assert.equal(isAllowedForScope("read", "POST", "/api/v1/location"), false);
  assert.equal(isAllowedForScope("read", "DELETE", "/api/v1/history"), false);
  assert.equal(isAllowedForScope("read", "PATCH", "/api/v1/profile"), false);
  assert.equal(
    isAllowedForScope("read", "PUT", "/api/v1/sharing/:viewerId"),
    false,
  );
  assert.equal(
    isAllowedForScope("read", "POST", "/api/v1/users/:userId/location-refresh"),
    false,
  );
});

test("write tokens may do anything the session can", () => {
  for (const method of ["GET", "POST", "PUT", "PATCH", "DELETE"]) {
    assert.equal(isAllowedForScope("write", method, "/api/v1/history"), true);
  }
});
