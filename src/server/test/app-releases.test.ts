import assert from "node:assert/strict";
import { test } from "node:test";

import { pickLatestAndroidRelease } from "../src/services/app-releases";

const DIGEST = "a".repeat(64);

function release(tag: string, overrides: Record<string, unknown> = {}) {
  return {
    tag_name: tag,
    draft: false,
    prerelease: false,
    body: "Fixes",
    published_at: "2026-10-10T10:00:00Z",
    assets: [
      {
        name: "legacytracker.apk",
        state: "uploaded",
        size: 31_000_000,
        digest: `sha256:${DIGEST}`,
        browser_download_url: `https://github.com/o/r/releases/download/${tag}/legacytracker.apk`,
      },
    ],
    ...overrides,
  };
}

test("picks the highest version code, not the newest listing", () => {
  const latest = pickLatestAndroidRelease([
    release("android-v1.1.0+11"),
    release("android-v1.2.0+12"),
    release("android-v1.0.9+9"),
  ]);
  assert.equal(latest?.versionCode, 12);
  assert.equal(latest?.versionName, "1.2.0");
  assert.equal(latest?.sha256, DIGEST);
  assert.equal(latest?.size, 31_000_000);
  assert.equal(latest?.notes, "Fixes");
});

test("skips drafts, prereleases and other tags", () => {
  const latest = pickLatestAndroidRelease([
    release("android-v2.0.0+20", { draft: true }),
    release("android-v1.9.0+19", { prerelease: true }),
    release("v3.0.0"),
    release("ios-v1.0.0+30"),
    release("android-v1.0.0+5"),
  ]);
  assert.equal(latest?.versionCode, 5);
});

test("skips releases without a complete, verifiable APK", () => {
  const asset = release("x").assets[0];
  const latest = pickLatestAndroidRelease([
    release("android-v1.4.0+14", { assets: [] }),
    release("android-v1.3.0+13", { assets: [{ ...asset, state: "open" }] }),
    release("android-v1.2.0+12", { assets: [{ ...asset, digest: null }] }),
    release("android-v1.1.0+11", { assets: [{ ...asset, name: "notes.txt" }] }),
    release("android-v1.0.0+10"),
  ]);
  assert.equal(latest?.versionCode, 10);
});

test("keeps pre-release suffixes in the version name", () => {
  const latest = pickLatestAndroidRelease([release("android-v1.2.0-beta.1+42")]);
  assert.equal(latest?.versionName, "1.2.0-beta.1");
  assert.equal(latest?.versionCode, 42);
});

test("returns null for no usable release or a malformed response", () => {
  assert.equal(pickLatestAndroidRelease([]), null);
  assert.equal(pickLatestAndroidRelease({ message: "Not Found" }), null);
  assert.equal(pickLatestAndroidRelease([null, 3, "x"]), null);
});
