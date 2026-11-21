import assert from "node:assert/strict";
import { test } from "node:test";

import {
  pickLatestAndroidRelease,
  pickLatestNightlyRelease,
} from "../src/services/app-releases";

const DIGEST = "a".repeat(64);
const COMMIT = "0ef1325";

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
  const latest = pickLatestAndroidRelease([
    release("android-v1.2.0-beta.1+42"),
  ]);
  assert.equal(latest?.versionName, "1.2.0-beta.1");
  assert.equal(latest?.versionCode, 42);
});

test("returns null for no usable release or a malformed response", () => {
  assert.equal(pickLatestAndroidRelease([]), null);
  assert.equal(pickLatestAndroidRelease({ message: "Not Found" }), null);
  assert.equal(pickLatestAndroidRelease([null, 3, "x"]), null);
});

function nightlyBody(commit = COMMIT, code = 29, name = "1.8.0") {
  return `Nightly build from commit ${commit}.\n\n<!-- legacytracker-nightly {"version_name":"${name}","version_code":${code},"commit":"${commit}"} -->`;
}

function nightlyRelease(
  createdAt = "2026-11-21T10:00:00Z",
  overrides: Record<string, unknown> = {},
) {
  return {
    tag_name: "nightly",
    draft: false,
    prerelease: true,
    body: nightlyBody(),
    published_at: "2026-11-01T10:00:00Z",
    assets: [
      {
        name: `legacytracker-${COMMIT}.apk`,
        state: "uploaded",
        created_at: createdAt,
        size: 129_000_000,
        digest: `sha256:${DIGEST}`,
        browser_download_url: `https://github.com/o/r/releases/download/nightly/legacytracker-${COMMIT}.apk`,
      },
      {
        name: `LegacyTracker-${COMMIT}.ipa`,
        state: "uploaded",
        created_at: createdAt,
        size: 60_000_000,
        digest: `sha256:${"b".repeat(64)}`,
        browser_download_url: `https://github.com/o/r/releases/download/nightly/LegacyTracker-${COMMIT}.ipa`,
      },
    ],
    ...overrides,
  };
}

test("the stable feed never sees the nightly prerelease", () => {
  const latest = pickLatestAndroidRelease([
    nightlyRelease(),
    release("android-v1.0.0+5"),
  ]);
  assert.equal(latest?.versionCode, 5);
  // Even if someone forgot to mark it as a prerelease, the tag is not stable.
  assert.equal(
    pickLatestAndroidRelease([nightlyRelease(undefined, { prerelease: false })])
      ?.versionCode,
    undefined,
  );
});

test("the nightly feed reads the metadata and the newest matching APK", () => {
  const old = nightlyRelease("2026-11-20T10:00:00Z", {
    assets: [
      {
        name: `legacytracker-${COMMIT}.apk`,
        state: "uploaded",
        created_at: "2026-11-20T10:00:00Z",
        size: 1,
        digest: `sha256:${"c".repeat(64)}`,
        browser_download_url: "https://example.invalid/old.apk",
      },
    ],
  });
  const nightly = pickLatestNightlyRelease([
    old,
    nightlyRelease("2026-11-21T10:00:00Z"),
  ]);
  assert.equal(nightly?.commit, COMMIT);
  assert.equal(nightly?.versionCode, 29);
  assert.equal(nightly?.versionName, "1.8.0+nightly.0ef1325");
  assert.equal(nightly?.size, 129_000_000);
  assert.ok(nightly?.apkUrl.endsWith(`legacytracker-${COMMIT}.apk`));
  // The machine-readable line is not user-facing release notes.
  assert.equal(nightly?.notes, "Nightly build from commit 0ef1325.");
  assert.equal(nightly?.publishedAt, "2026-11-21T10:00:00Z");
});

test("the nightly feed ignores stable releases and malformed prereleases", () => {
  const asset = nightlyRelease().assets[0];
  assert.equal(pickLatestNightlyRelease([release("android-v9.9.9+99")]), null);
  assert.equal(
    pickLatestNightlyRelease([
      nightlyRelease(undefined, { prerelease: false }),
    ]),
    null,
  );
  assert.equal(
    pickLatestNightlyRelease([nightlyRelease(undefined, { draft: true })]),
    null,
  );
  assert.equal(
    pickLatestNightlyRelease([
      nightlyRelease(undefined, { body: "no metadata" }),
    ]),
    null,
  );
  assert.equal(
    pickLatestNightlyRelease([
      nightlyRelease(undefined, { body: nightlyBody("deadbee", 29) }),
    ]),
    null,
  );
  assert.equal(
    pickLatestNightlyRelease([
      nightlyRelease(undefined, { assets: [{ ...asset, state: "open" }] }),
    ]),
    null,
  );
  assert.equal(pickLatestNightlyRelease([]), null);
  assert.equal(pickLatestNightlyRelease({ message: "Not Found" }), null);
});
