import assert from "node:assert/strict";
import { test } from "node:test";

import { mapLimit } from "../src/services/concurrency";

test("results keep input order and concurrency stays bounded", async () => {
  let running = 0;
  let peak = 0;
  const out = await mapLimit([1, 2, 3, 4, 5, 6], 2, async (n) => {
    running++;
    peak = Math.max(peak, running);
    await new Promise((resolve) => setTimeout(resolve, 5 - (n % 3)));
    running--;
    return n * 10;
  });
  assert.deepEqual(out, [10, 20, 30, 40, 50, 60]);
  assert.equal(peak, 2);
});

test("an empty list resolves to an empty list", async () => {
  assert.deepEqual(await mapLimit([], 3, async (n: number) => n), []);
});
