/**
 * Android builds are distributed outside the Play Store as GitHub releases
 * tagged `android-v<versionName>+<versionCode>` (the pubspec `version:`
 * format), each carrying one .apk asset plus an unsigned .ipa — see
 * scripts/release-android.sh.
 *
 * Devices ask this server rather than GitHub which release is current: one
 * cached lookup serves every phone (GitHub allows 60 unauthenticated API
 * calls an hour per IP), and the server can announce a new release over FCM.
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

const TAG_PATTERN = /^android-v(.+)\+(\d+)$/;
const DIGEST_PATTERN = /^sha256:([0-9a-f]{64})$/;
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
 * response, by version code. Drafts, prereleases (useful for staging a build
 * before rolling it out), other tags and releases without a verifiable APK
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

export interface AndroidReleaseSourceOptions {
  /** `owner/name` of the GitHub repository the releases are published to. */
  repo: string;
  /** Optional token, only to raise GitHub's rate limit. */
  token?: string;
  ttlMs: number;
}

/** Cached view of the current Android release. */
export class AndroidReleaseSource {
  private cached: { release: AndroidRelease | null; at: number } | null = null;
  private inflight: Promise<AndroidRelease | null> | null = null;

  constructor(private readonly options: AndroidReleaseSourceOptions) {}

  /**
   * The current release, or null when none is published. While GitHub is
   * unreachable the last known answer is served; with none it throws.
   */
  async latest(): Promise<AndroidRelease | null> {
    if (this.cached && Date.now() - this.cached.at < this.options.ttlMs) {
      return this.cached.release;
    }
    this.inflight ??= this.refresh().finally(() => {
      this.inflight = null;
    });
    return this.inflight;
  }

  private async refresh(): Promise<AndroidRelease | null> {
    const headers: Record<string, string> = {
      Accept: "application/vnd.github+json",
      "User-Agent": "legacytracker-server",
      "X-GitHub-Api-Version": "2022-11-28",
    };
    if (this.options.token) {
      headers.Authorization = `Bearer ${this.options.token}`;
    }
    try {
      const response = await fetch(
        `https://api.github.com/repos/${this.options.repo}/releases?per_page=30`,
        { headers, signal: AbortSignal.timeout(10_000) },
      );
      if (!response.ok) {
        throw new Error(`GitHub releases: HTTP ${response.status}`);
      }
      const release = pickLatestAndroidRelease(await response.json());
      this.cached = { release, at: Date.now() };
      return release;
    } catch (error) {
      if (this.cached) {
        return this.cached.release;
      }
      throw error;
    }
  }
}
