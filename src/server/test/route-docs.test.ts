import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";

// CLAUDE.md requires every endpoint to be documented in the OpenAPI document
// (src/web/src/lib/openapi.ts) and the server README. This makes the rule a
// failing test instead of a convention.
const root = join(__dirname, "..");
const appSource = readFileSync(join(root, "src", "app.ts"), "utf8");
const openapi = readFileSync(
  join(root, "..", "web", "src", "lib", "openapi.ts"),
  "utf8",
);
const readme = readFileSync(join(root, "README.md"), "utf8");

const ROUTE = /\bapp\.(get|post|put|patch|delete)\(\s*["'`]([^"'`]+)["'`]/g;

function routes(): { method: string; path: string }[] {
  const found: { method: string; path: string }[] = [];
  for (const match of appSource.matchAll(ROUTE)) {
    found.push({ method: match[1].toUpperCase(), path: match[2] });
  }
  return found;
}

// Routes deliberately left out of the public API reference.
const NOT_PUBLIC = new Set<string>(["POST /auth/backchannel-logout"]);

describe("route documentation", () => {
  const all = routes().filter(
    ({ method, path }) => !NOT_PUBLIC.has(`${method} ${path}`),
  );

  it("finds the route table", () => {
    assert.ok(all.length > 20, `only ${all.length} routes found`);
  });

  for (const { method, path } of all) {
    const openapiPath = path.replace(/:(\w+)/g, "{$1}");

    it(`${method} ${path} is in openapi.ts`, () => {
      assert.ok(
        openapi.includes(`'${openapiPath}'`),
        `${openapiPath} is missing from src/web/src/lib/openapi.ts`,
      );
    });

    it(`${method} ${path} is in the README`, () => {
      assert.ok(
        readme.includes(path),
        `${path} is missing from src/server/README.md`,
      );
    });
  }
});
