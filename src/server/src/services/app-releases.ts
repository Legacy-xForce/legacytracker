/**
 * Android builds are distributed outside the Play Store as GitHub releases
 * tagged `android-v<versionName>+<versionCode>` (the pubspec `version:`
 * format), each carrying one .apk asset plus an unsigned .ipa — see
 * scripts/release-android.sh.
 *
 * On top of that, CI publishes raw, optimized builds to a rolling `nightly`
 * prerelease (see .github/workflows/ci.yml). The stable feed MUST never see
 * that release: it is a prerelease and its tag does not match the stable tag
 * pattern. The nightly feed only ever reads the `nightly` tag.
 *
 * Devices ask this server rather than GitHub which release is current: one
 * cached lookup serves every phone (GitHub allows 60 unauthenticated API
 * calls an hour per IP), and the server can announce a new stable release over
 * FCM. Nightlies are deliberately never pushed — they are picked up on the
 * app's own checks by devices whose owner opted into the nightly channel.
 */

export interface AndroidRelease {
  versionCode: number;
  versionName: string;
  apkUrl: string;
  /** Hex SHA-256 of the APK, from GitHub's asset digest. */
  sha256: string;
  size: number;
  notes: string;
  publishedAt: string | null;
}

/** A build from the rolling prerelease, plus the commit it was built from. */
export interface NightlyRelease extends AndroidRelease {
  commit: string;
}

const TAG_PATTERN = /^android-v(.+)\+(\d+)$/;
const NIGHTLY_TAG = "nightly";
// CI writes one machine-readable line into the prerelease body; everything
// else in the body is shown to the user as release notes.
const NIGHTLY_META_PATTERN =
  /<!--\s*legacytracker-nightly\s+(\{[^\r\n]*?\})\s*-->/;
const DIGEST_PATTERN = /^sha256:([0-9a-f]{64})$/;
const COMMIT_PATTERN = /^[0-9a-f]{7,40}$/;
const MAX_NOTES_LENGTH = 2000;

type Json = Record<string, unknown>;

function isObject(value: unknown): value is Json {
  return typeof value === "object" && value !== null;
}

function parseRelease(raw: unknown): AndroidRelease | null {
  if (!isObject(raw) || raw.draft === true || raw.prerelease === true) {
    return null;
  }
  const match =
    typeof raw.tag_name === "string" ? TAG_PATTERN.exec(raw.tag_name) : null;
  if (!match) {
    return null;
  }
  const versionCode = Number(match[2]);
  if (!Number.isSafeInteger(versionCode) || versionCode <= 0) {
    return null;
  }

  // An asset still uploading is listed with state "open".
  const assets = Array.isArray(raw.assets) ? raw.assets.filter(isObject) : [];
  const apk = assets.find(
    (asset) =>
      typeof asset.name === "string" &&
      asset.name.endsWith(".apk") &&
      (asset.state === undefined || asset.state === "uploaded"),
  );
  if (!apk) {
    return null;
  }
  const digest =
    typeof apk.digest === "string" ? DIGEST_PATTERN.exec(apk.digest) : null;
  if (
    !digest ||
    typeof apk.size !== "number" ||
    typeof apk.browser_download_url !== "string"
  ) {
    return null;
  }

  return {
    versionCode,
    versionName: match[1],
    apkUrl: apk.browser_download_url,
    sha256: digest[1],
    size: apk.size,
    notes:
      typeof raw.body === "string"
        ? raw.body.trim().slice(0, MAX_NOTES_LENGTH)
        : "",
    publishedAt: typeof raw.published_at === "string" ? raw.published_at : null,
  };
}

/**
 * The newest installable Android release in a GitHub `GET /releases`
 * response, by version code. Drafts, prereleases (nightlies and builds being
 * staged before rollout), other tags and releases without a verifiable APK
 * are skipped.
 */
export function pickLatestAndroidRelease(
  releases: unknown,
): AndroidRelease | null {
  if (!Array.isArray(releases)) {
    return null;
  }
  let latest: AndroidRelease | null = null;
  for (const raw of releases) {
    const release = parseRelease(raw);
    if (release && (!latest || release.versionCode > latest.versionCode)) {
      latest = release;
    }
  }
  return latest;
}

type ParsedNightly = NightlyRelease & { assetAt: string };

/** The rolling `nightly` prerelease, only when its metadata and APK agree. */
function parseNightlyRelease(raw: unknown): ParsedNightly | null {
  if (!isObject(raw) || raw.draft === true || raw.prerelease !== true) {
    return null;
  }
  if (raw.tag_name !== NIGHTLY_TAG || typeof raw.body !== "string") {
    return null;
  }
  const meta = NIGHTLY_META_PATTERN.exec(raw.body);
  if (!meta) {
    return null;
  }
  let info: Json;
  try {
    const parsed: unknown = JSON.parse(meta[1]);
    if (!isObject(parsed)) return null;
    info = parsed;
  } catch {
    return null;
  }
  const versionCode = Number(info.version_code);
  const { version_name: versionName, commit } = info;
  if (
    !Number.isSafeInteger(versionCode) ||
    versionCode <= 0 ||
    typeof versionName !== "string" ||
    !versionName ||
    typeof commit !== "string" ||
    !COMMIT_PATTERN.test(commit)
  ) {
    return null;
  }

  // Several nightlies are kept for rollback; the newest uploaded asset wins.
  // Its name pins the commit, so a stale body can't serve a different APK.
  const assets = Array.isArray(raw.assets) ? raw.assets.filter(isObject) : [];
  const apks = assets.filter(
    (asset) =>
      asset.name === `legacytracker-${commit}.apk` &&
      (asset.state === undefined || asset.state === "uploaded"),
  );
  if (apks.length === 0) {
    return null;
  }
  const apk = apks.reduce((newest, candidate) =>
    String(candidate.created_at ?? "") > String(newest.created_at ?? "")
      ? candidate
      : newest,
  );
  const digest =
    typeof apk.digest === "string" ? DIGEST_PATTERN.exec(apk.digest) : null;
  if (
    !digest ||
    typeof apk.size !== "number" ||
    typeof apk.browser_download_url !== "string"
  ) {
    return null;
  }

  return {
    versionCode,
    // The commit in the name is what the app compares when it is on nightly:
    // two builds of the same pubspec version must still be distinguishable.
    versionName: `${versionName}+nightly.${commit}`,
    commit,
    apkUrl: apk.browser_download_url,
    sha256: digest[1],
    size: apk.size,
    notes: raw.body
      .replace(NIGHTLY_META_PATTERN, "")
      .trim()
      .slice(0, MAX_NOTES_LENGTH),
    publishedAt: typeof apk.created_at === "string" ? apk.created_at : null,
    assetAt: typeof apk.created_at === "string" ? apk.created_at : "",
  };
}

/** The newest nightly build, or null when the prerelease is absent/invalid. */
export function pickLatestNightlyRelease(
  releases: unknown,
): NightlyRelease | null {
  if (!Array.isArray(releases)) {
    return null;
  }
  let latest: ParsedNightly | null = null;
  for (const raw of releases) {
    const nightly = parseNightlyRelease(raw);
    if (nightly && (!latest || nightly.assetAt > latest.assetAt)) {
      latest = nightly;
    }
  }
  if (!latest) return null;
  const { assetAt: _assetAt, ...release } = latest;
  return release;
}

export interface AndroidReleaseSourceOptions {
  /** `owner/name` of the GitHub repository the releases are published to. */
  repo: string;
  /** Optional token, only to raise GitHub's rate limit. */
  token?: string;
  ttlMs: number;
}

interface CachedReleases {
  stable: AndroidRelease | null;
  nightly: NightlyRelease | null;
  at: number;
}

/** Cached view of both update channels, from one GitHub lookup. */
export class AndroidReleaseSource {
  private cached: CachedReleases | null = null;
  private inflight: Promise<CachedReleases> | null = null;

  constructor(private readonly options: AndroidReleaseSourceOptions) {}

  /** The current stable release, or null when none is published. */
  async latest(): Promise<AndroidRelease | null> {
    return (await this.refresh()).stable;
  }

  /** The current nightly build, or null when the prerelease has no usable APK. */
  async latestNightly(): Promise<NightlyRelease | null> {
    return (await this.refresh()).nightly;
  }

  private refresh(): Promise<CachedReleases> {
    if (this.cached && Date.now() - this.cached.at < this.options.ttlMs) {
      return Promise.resolve(this.cached);
    }
    this.inflight ??= this.fetch().finally(() => {
      this.inflight = null;
    });
    return this.inflight;
  }

  private async fetch(): Promise<CachedReleases> {
    const headers: Record<string, string> = {
      Accept: "application/vnd.github+json",
      "User-Agent": "legacytracker-server",
      "X-GitHub-Api-Version": "2022-11-28",
    };
    if (this.options.token) {
      headers.Authorization = `Bearer ${this.options.token}`;
    }
    try {
      // The rolling nightly release keeps its original created_at, so it can
      // sink in the list as stable releases accumulate. Read the full page.
      const response = await fetch(
        `https://api.github.com/repos/${this.options.repo}/releases?per_page=100`,
        { headers, signal: AbortSignal.timeout(10_000) },
      );
      if (!response.ok) {
        throw new Error(`GitHub releases: HTTP ${response.status}`);
      }
      const releases = await response.json();
      this.cached = {
        stable: pickLatestAndroidRelease(releases),
        nightly: pickLatestNightlyRelease(releases),
        at: Date.now(),
      };
      return this.cached;
    } catch (error) {
      if (this.cached) {
        return this.cached;
      }
      throw error;
    }
  }
}
