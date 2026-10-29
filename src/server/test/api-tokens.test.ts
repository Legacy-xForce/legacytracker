import assert from "node:assert/strict";
import { test } from "node:test";
import type { Pool } from "pg";

import {
  ApiTokens,
  apiTokenHint,
  generateApiToken,
  hashApiToken,
  ipMatchesAllowlist,
  isAllowedForScope,
  isApiTokenId,
  isApiTokenShape,
  MAX_ALLOWED_IPS_PER_TOKEN,
  MAX_API_TOKEN_NAME_LENGTH,
  normalizeIp,
  parseAllowedIps,
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

test("addresses normalise, and anything else is refused", () => {
  assert.equal(normalizeIp(" 203.0.113.7 "), "203.0.113.7");
  assert.equal(normalizeIp("2001:DB8::1"), "2001:db8::1");
  assert.equal(normalizeIp("::1"), "::1");
  // What a dual-stack socket reports for an IPv4 peer is that IPv4 address.
  assert.equal(normalizeIp("::ffff:203.0.113.7"), "203.0.113.7");
  assert.equal(normalizeIp("203.0.113.7/24"), null);
  assert.equal(normalizeIp("fe80::1%eth0"), null);
  assert.equal(normalizeIp("tracker.example.com"), null);
  assert.equal(normalizeIp("203.0.113"), null);
  assert.equal(normalizeIp(""), null);
});

test("allowlists hold addresses and prefixes, canonically written", () => {
  assert.deepEqual(
    parseAllowedIps(["203.0.113.7", " 203.0.113.0/24 ", "2001:DB8::/64"]),
    { ok: true, value: ["203.0.113.7", "203.0.113.0/24", "2001:db8::/64"] },
  );
  assert.deepEqual(parseAllowedIps(["::ffff:203.0.113.7"]), {
    ok: true,
    value: ["203.0.113.7"],
  });
  assert.deepEqual(parseAllowedIps(["172.20.0.4", "172.20.0.4/32"]), {
    ok: true,
    value: ["172.20.0.4"],
  });
  assert.deepEqual(parseAllowedIps([]), { ok: true, value: [] });
});

test("a bad entry is named, and a long list is refused", () => {
  assert.deepEqual(parseAllowedIps(["203.0.113.7", "nope"]), {
    ok: false,
    error: "`nope` is not an IP address or CIDR prefix",
  });
  assert.deepEqual(parseAllowedIps(["203.0.113.7/33"]), {
    ok: false,
    error: "`203.0.113.7/33` is not an IP address or CIDR prefix",
  });
  for (const value of [
    "203.0.113.7/",
    "203.0.113.7/24/8",
    "/24",
    "",
    "fe80::1%eth0",
    "2001:db8::/129",
    42,
  ]) {
    assert.equal(parseAllowedIps([value]).ok, false, String(value));
  }
  assert.equal(parseAllowedIps("203.0.113.7").ok, false);
  assert.equal(parseAllowedIps(undefined).ok, false);
  assert.equal(
    parseAllowedIps(
      Array.from({ length: MAX_ALLOWED_IPS_PER_TOKEN + 1 }, (_, i) =>
        `203.0.113.${i}`,
      ),
    ).ok,
    false,
  );
});

test("an empty allowlist restricts nobody", () => {
  assert.equal(ipMatchesAllowlist("203.0.113.7", []), true);
  assert.equal(ipMatchesAllowlist("2001:db8::1", []), true);
});

test("addresses and prefixes match by their leading bits", () => {
  assert.equal(ipMatchesAllowlist("203.0.113.7", ["203.0.113.7"]), true);
  assert.equal(ipMatchesAllowlist("203.0.113.8", ["203.0.113.7"]), false);
  assert.equal(ipMatchesAllowlist("203.0.113.7", ["203.0.113.7/32"]), true);
  assert.equal(ipMatchesAllowlist("203.0.113.99", ["203.0.113.0/24"]), true);
  assert.equal(ipMatchesAllowlist("203.0.112.99", ["203.0.113.0/24"]), false);
  assert.equal(ipMatchesAllowlist("203.0.113.64", ["203.0.113.64/26"]), true);
  assert.equal(ipMatchesAllowlist("203.0.113.99", ["203.0.113.64/26"]), true);
  assert.equal(ipMatchesAllowlist("203.0.113.127", ["203.0.113.64/26"]), true);
  assert.equal(ipMatchesAllowlist("203.0.113.63", ["203.0.113.64/26"]), false);
  assert.equal(ipMatchesAllowlist("203.0.113.128", ["203.0.113.64/26"]), false);
  assert.equal(ipMatchesAllowlist("8.8.8.8", ["0.0.0.0/0"]), true);
  assert.equal(ipMatchesAllowlist("2001:db8:1::5", ["2001:db8::/32"]), true);
  assert.equal(ipMatchesAllowlist("2001:db9:1::5", ["2001:db8::/32"]), false);
  // 2001:db8::/64 is the first /64 only: word 4 must still be zero.
  assert.equal(ipMatchesAllowlist("2001:db8::1:2:3:4", ["2001:db8::/64"]), true);
  assert.equal(ipMatchesAllowlist("2001:db8:1::2", ["2001:db8::/64"]), false);
});

test("one token can list both families", () => {
  const allowed = ["203.0.113.0/24", "2001:db8::/32"];
  assert.equal(ipMatchesAllowlist("203.0.113.20", allowed), true);
  assert.equal(ipMatchesAllowlist("2001:db8:dead::1", allowed), true);
  assert.equal(ipMatchesAllowlist("198.51.100.1", allowed), false);
  // A socket's IPv4-mapped form is the same host as the dotted quad.
  assert.equal(ipMatchesAllowlist("::ffff:203.0.113.20", allowed), true);
  // Families never cross, so listing IPv4 alone does not admit IPv6 callers.
  assert.equal(ipMatchesAllowlist("2001:db8::1", ["0.0.0.0/0"]), false);
  assert.equal(ipMatchesAllowlist("203.0.113.7", ["::/0"]), false);
});

test("deleting a token marks it deleted and keeps its history", async () => {
  const calls: string[] = [];
  const pool = {
    query: async (text: string) => {
      calls.push(text);
      return {
        rows: [{ id: "id", token_hash: "hash" }],
        rowCount: 1,
      };
    },
  } as unknown as Pool;

  assert.equal(await new ApiTokens(pool).remove("user-1", "id"), true);
  assert.match(calls[0], /UPDATE api_tokens SET deleted = true/);
  assert.doesNotMatch(calls[0], /DELETE FROM api_tokens/);
});
