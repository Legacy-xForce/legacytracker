import assert from "node:assert/strict";
import { test } from "node:test";
import type { Pool } from "pg";

import {
  ApiTokenRequests,
  MAX_USER_AGENT_LENGTH,
  requestPath,
  userAgentOf,
  type ApiTokenRequestEntry,
} from "../src/services/api-token-requests";

const entry: ApiTokenRequestEntry = {
  tokenId: "0e7a3c3e-2f7b-4f63-9c55-0bb0a4f3c1d2",
  userId: "user-1",
  method: "GET",
  path: "/api/v1/history",
  statusCode: 200,
  clientIp: "203.0.113.7",
  userAgent: "Home Assistant/2026.10",
  durationMs: 12,
};

test("query strings stay out of the audit trail", () => {
  assert.equal(requestPath("/api/v1/history?since=2026-10-01"), "/api/v1/history");
  assert.equal(requestPath("/api/v1/history"), "/api/v1/history");
  assert.equal(requestPath("/api/v1/history?"), "/api/v1/history");
});

test("the user agent is kept, bounded and optional", () => {
  assert.equal(userAgentOf("curl/8.0"), "curl/8.0");
  assert.equal(userAgentOf(undefined), null);
  assert.equal(userAgentOf(""), null);
  assert.equal(userAgentOf(["first", "second"]), "first");
  const long = "x".repeat(MAX_USER_AGENT_LENGTH + 20);
  assert.equal(userAgentOf(long)?.length, MAX_USER_AGENT_LENGTH);
});

test("recording a request inserts every field", async () => {
  const calls: Array<{ text: string; values: unknown[] }> = [];
  const pool = {
    query: async (text: string, values: unknown[]) => {
      calls.push({ text, values });
      return { rows: [], rowCount: 1 };
    },
  } as unknown as Pool;

  await new ApiTokenRequests(pool).record(entry);

  assert.equal(calls.length, 1);
  assert.match(calls[0].text, /INSERT INTO api_token_requests/);
  assert.deepEqual(calls[0].values, [
    entry.tokenId,
    entry.userId,
    entry.method,
    entry.path,
    entry.statusCode,
    entry.clientIp,
    entry.userAgent,
    entry.durationMs,
  ]);
});

test("a failed write reaches the caller so it can be logged", async () => {
  const pool = {
    query: async () => {
      throw new Error("database unavailable");
    },
  } as unknown as Pool;

  await assert.rejects(
    new ApiTokenRequests(pool).record(entry),
    /database unavailable/,
  );
});
