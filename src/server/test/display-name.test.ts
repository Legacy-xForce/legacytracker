import assert from "node:assert/strict";
import { test } from "node:test";

import { getDisplayNameFromToken } from "../src/services/display-name";

test("uses the display name instead of the lowercase login name", () => {
  assert.equal(
    getDisplayNameFromToken(
      {
        username: "alice",
        preferred_username: "alice",
        display_name: "Alice",
        name: "Alice Smith",
      },
      "user-1",
    ),
    "Alice",
  );
});

test("uses the standard name claim when display_name is absent", () => {
  assert.equal(
    getDisplayNameFromToken(
      { username: "alice", preferred_username: "alice", name: "Alice" },
      "user-1",
    ),
    "Alice",
  );
});

test("falls back to the login name for older tokens", () => {
  assert.equal(
    getDisplayNameFromToken(
      { username: "alice", preferred_username: "alice" },
      "user-1",
    ),
    "alice",
  );
});

test("ignores blank claims and a name equal to the subject", () => {
  assert.equal(
    getDisplayNameFromToken(
      {
        display_name: "  ",
        name: "user-1",
        preferred_username: "user-1",
        username: "alice",
      },
      "user-1",
    ),
    "alice",
  );
});
