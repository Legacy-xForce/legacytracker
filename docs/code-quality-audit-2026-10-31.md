# Code Quality Audit — 2026-10-31

A repo-wide sweep for **duplicated, obsolete, redundant and non-optimized code**, written so each
finding below can be pasted straight into a GitHub issue.

## Scope and method

| Package | What was read | Size |
|---|---|---|
| `src/client` (Flutter/Dart) | `lib/**` in full + `test/**` | 126 files / 26.7k lines |
| `src/client` (native) | Kotlin under `android/app/src/**`, Swift in `ios/Runner/**`, manifests/plists | 28 files / 5.8k lines |
| `src/server` | `src/**` in full + `test/**` + `schema.sql` + Dockerfile | 42 files / 7.4k lines |
| `src/web` | every `.vue`, plus `api/`, `stores/`, `lib/`, `composables/`, `theme/`, `style.css` | 134 files / 15.8k lines |
| Repo | `.github/workflows/*`, `scripts/`, `docs/`, `CLAUDE.md`, READMEs, lockfiles, `.gitignore`/`.dockerignore` | — |

Static analysis only: no source file was modified, no build or test was run, and nothing touched the
production database or Firebase project referenced by `src/server/.env`.

## Headlines

1. **The server has no CI at all.** No `npm ci`, no `tsc`, no `npm test` in any workflow; its 19 test files
   never execute, and the only type check is inside `Dockerfile:6`, which runs *after* merge — while a
   push to `main` publishes the production `:latest` image (A-1).
2. **The Kotlin engine tests never run either**, so the tracking engine's documented safety net is
   unenforced (A-2) — which matters because the iOS port is already missing two of its behaviours: the
   stationary fast-stop and the jitter filter (D-2). Both are live user-visible bugs on iPhone.
3. **Two hot paths scale with the wrong variable.** `GET /api/v1/leaderboard` issues one unbounded query
   per registered user (B-1), and each single WebSocket point in the web app clones the whole peer Map,
   re-renders every marker and re-clusters from scratch (E-1, with the Flutter twin in C-7).
4. **`src/server/.dockerignore` does not exclude `.env`** — the file `CLAUDE.md:75` says holds the shared
   database URL and a live Firebase key — so it lands in image layers (A-3).
5. **About a seventh of the client's Dart network code is copy-paste** (~150 of ~1100 lines), and roughly
   200 lines of the API-token screens and 170 lines of the web dialog/state blocks are the same five
   widgets re-declared per file (C-1, C-3, E-2).
6. **The rules in `CLAUDE.md` are not true of the code.** Nominatim is *not* throttled to one request per
   1.1 s in the app — street labels fire unthrottled reverse lookups from an unbounded cache (C-4); the
   endpoint list is hand-maintained in five places (A-4); and `MockBackend`, described as live, is
   imported by nothing and can be deleted (C-11).

Every finding carries `file:line` evidence. All high-priority findings were re-checked by hand after
the initial sweep. The "Checked and clean" appendix lists what was looked for and *not* found, so no
issue gets filed twice.

## Labels

- **Kind**: `kind/duplicate` · `kind/dead-code` · `kind/redundant` · `kind/perf` · `kind/drift` · `ci` · `docs`
- **Area**: `area/client` · `area/native` · `area/server` · `area/web` · `area/repo`
- **Priority**: `priority/high` (user-visible bug, hot path, or shipped weight/risk) · `priority/medium` · `priority/low`
- **Effort**: `S` (under half a day) · `M` (a day or two) · `L` (multi-day, cross-package)

## Tally

78 findings. Each is counted under its **primary** kind; a few carry a second kind tag in their own line.

| Kind | high | medium | low | total |
|---|---|---|---|---|
| duplicated | 8 | 21 | 0 | 29 |
| non-optimized | 6 | 15 | 2 | 23 |
| obsolete / dead | 3 | 5 | 9 | 17 |
| redundant | 1 | 3 | 0 | 4 |
| drift (doc vs code) | 1 | 2 | 1 | 4 |
| ci / docs tooling | 1 | 0 | 0 | 1 |
| **total** | **20** | **46** | **12** | **78** |

Per package: repo & cross-cutting **16**, server **14**, Flutter client **21**, native engines **9**
(plus a Kotlin/Swift constant cross-check table, D-10), web logic **10**, web UI **8**.

Effort: 47 `S`, 28 `M`, 3 `L` — the bulk is mechanical deletion or a one-file refactor. The three `L`
entries are A-4 (generated API contract), A-8 (single design-token source) and D-1 (splitting the iOS
engine), all of which are structural rather than urgent.

Rough redundant-code footprint observed: ~150 lines of copy-pasted Dart network plumbing, ~200 lines in
the three API-token screens, ~170 lines in the web dialog/state blocks, ~120 lines of repeated Tailwind
class strings, ~100 lines of server route boilerplate, ~130 lines of unreachable mock backend, ~60 lines
of unused CSS token declarations, plus 1714 lines of iOS engine that duplicate the Kotlin module layout.

## Suggested order of attack

**Tier 1 — correctness and risk, do first**

| # | Finding | Why now |
|---|---|---|
| A-1 | Server is never compiled or tested in CI | A PR that does not build can merge, and the first check of it runs *after* the image is published `:latest` |
| A-3 | `.dockerignore` does not exclude `.env` | A developer's live DB URL and Firebase key land in image layers |
| D-2 | iOS is missing the fast stop and the jitter filter | The parked-car failure the tracking redesign exists to prevent, still live on iOS |
| E-1 | Peers store clones its Map and re-renders every marker per message | Costs scale with fleet size, not with what changed |
| B-1 | Leaderboard is one unbounded query per user | Slowest endpoint in the API, called by both clients |
| A-2 | Kotlin engine tests never run in CI | The tracking engine's whole safety net is unenforced |
| C-4 | Unthrottled Nominatim reverse lookups from the UI | Breaks the documented rate rule in the app; gets the shared quota blocked |
| F-1 | Hard-coded colours on markers and route dots | White borders vanish on the light theme |

**Tier 2 — structural, one PR each**: A-4 (endpoint contract), A-5 (Nominatim client), B-2 (dwell
seeding), B-5 (auth preHandler), C-1 (`ApiClient`), C-2 (tab rebuilds), C-3 (API-token screens),
D-1 (iOS engine split), E-2 (dialog shell), E-3 (token row), D-3 (main-thread SQLite).

**Tier 3 — deletions**: every `kind/dead-code` entry. All are low risk and most are `S`.

---

## A. Repo, CI, release and cross-package

### A-1 · Add a CI job that builds and unit-tests the server on every PR

**Kind:** `ci` · **Area:** `area/repo` · **Priority:** high · **Effort:** S

- `.github/workflows/ci.yml:10,50,89` — only `android`, `ios` and `web` jobs run on `pull_request`.
- `.github/workflows/ci.yml:112,136,189` — the three `server-docker*` jobs are gated
  `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`.
- Nowhere in any workflow: `npm ci`, `tsc`, `npm run build` or `npm test` for `src/server`. Its
  19 files in `src/server/test/` (`live-controller.test.ts`, `mapbox-tokens.test.ts`,
  `api-tokens.test.ts`, …) never execute.
- `src/server/Dockerfile:6` — `RUN npm run build` is the only type check in the repo for this
  package, and it runs post-merge.
- `CLAUDE.md:76` — pushing to `main` publishes the ghcr `:latest` image, so the first failing check
  of a server change can be after it is live.
- `src/server` also has no formatter or linter config at all (no `.prettierrc`, no eslint), while
  `ci.yml:101` runs `format:check` for `src/web` only.

**Impact:** a server change that does not compile, or that breaks a dwell/leaderboard/auth unit test,
merges and reaches production before anything goes red.

**Fix:** add a `server` job on `pull_request`: `npm ci` → `npm run build` → `npm test`. Adopt
`src/web/.prettierrc.json` for `src/server` and extend the format check to both.

### A-2 · Run the Kotlin engine tests in CI and deduplicate the workflow steps

**Kind:** `ci` `kind/duplicate` · **Area:** `area/repo` `area/native` · **Priority:** high · **Effort:** M

- `ci.yml:24,27,39` — the `android` job runs `flutter analyze`, `flutter test`, `flutter build apk`.
  No Gradle test step exists in any workflow, so the four engine tests that `CLAUDE.md:47` and
  `src/client/README.md:22` present as the tracking engine's safety net never run:
  `PathSamplerTest.kt`, `StopDetectorTest.kt`, `DriveSimulationTest.kt`, `TrackingIssuesTest.kt`.
- `src/client/ios/RunnerTests/RunnerTests.swift:7` — empty Xcode template; nothing runs it either.
- `mise.toml:42-46` runs `./gradlew` locally, so a green local run and a green CI disagree.
- Same block copy-pasted four times: checkout + `subosito/flutter-action@v2` with
  `flutter-version: 3.44.0` at `ci.yml:14-19`, `ci.yml:54-59`, `release-android.yml:127-131`,
  `release-android.yml:183-187`; the Gradle cache key at `ci.yml:30-37` ≡ `release-android.yml:135-140`;
  the SPM cache key at `ci.yml:64-67` ≡ `release-android.yml:196-201`; and the IPA packaging shell
  block pasted verbatim at `ci.yml:77-82` ≡ `release-android.yml:211-217`.
- `release-android.yml:122,243` re-declare Java 17 while `mise.toml:6` pins 21 and CI web uses 22.

**Impact:** sampler and stop-detection semantics can regress in a merge without a single test failing;
and any fix to the Flutter/Gradle/IPA boilerplate has to be applied in four places.

**Fix:** add `cd android && ./gradlew :app:testDebugUnitTest` to the `android` job; extract
`.github/actions/flutter-env` and `.github/actions/package-ipa`; single-source the Flutter version in
one repo variable consumed by all four jobs.

### A-3 · Close the ignore gaps: `.dockerignore` ships `.env`, `.kotlin/` and `.qoder/` are unignored

**Kind:** `kind/dead-code` · **Area:** `area/repo` · **Priority:** high · **Effort:** S

- `src/server/.dockerignore` — lists `node_modules`, `dist`, `.git`, `.vscode`, `.idea` and a stray
  `.dist`, but **not `.env`**. With `COPY . .` (`src/server/Dockerfile:4`) a developer's
  `src/server/.env` lands in the builder stage's layers. `CLAUDE.md:75` documents that this file
  holds the shared cloud database URL and a live Firebase key.
- `src/client/android/.gitignore:1-12` — covers `/.gradle`, `/local.properties`, `.cxx/`, not
  `.kotlin/`, which exists on disk (`src/client/android/.kotlin/sessions/`) and is matched by no rule;
  it is invisible today only because it is empty.
- Root `.gitignore:8-14` — ignores `.idea/`, offers `.vscode/` commented out while
  `.vscode/settings.json` is committed with a single `cmake.ignoreCMakeListsMissing` key that relates
  to no package here; `.qoder/` is ignored nowhere.

**Impact:** secret exposure through image layers, and near-certain accidental commits of Gradle/Kotlin
build state.

**Fix:** add `.env` (and `!.env.example`) to `src/server/.dockerignore`, `.kotlin/` to
`src/client/android/.gitignore`, `.qoder/` to the root file, and either drop `.vscode/settings.json`
or uncomment `.vscode/`.

### A-4 · Make the endpoint list one contract instead of five hand-synced copies

**Kind:** `kind/duplicate` · **Area:** `area/repo` · **Priority:** high · **Effort:** L

The same 28 paths are written out in five places, in three different placeholder syntaxes:

- `src/server/src/app.ts:1222,1230,1283,1320,1346,1398,1426,1472,1508,1560,1580,1608,1656,1689,1707,1716,1747,1767,1793,1816,1851,1878,1904,1957,2060,2139,2185,2233` — route literals (`:id` form).
- `src/web/src/lib/openapi.ts:182,229,251,294,328,413,527,580,637,710,730,777,808,841,867,909,941,1007,1038,1072,1133` — `{id}` form.
- `src/server/README.md:158-164,170-171,180-181,194,204,214-215,267-268,274,280-281,328` — prose tables.
- Dart services: `api_token_service.dart:41,66,90,106,127,149,171`, `checkpoint_service.dart:30,48,67,79`, `history_service.dart:32,75`, `sharing_service.dart:29,46`, `profile_service.dart:17,64`, `device_service.dart:41,65`, `mapbox_token_service.dart:65`, `location_refresh_service.dart:47`, `remote_backend.dart:66,137,360`, `leaderboard_service.dart:24`.
- Web: `api/apiTokens.ts:129,140,149,159,166,178,192`, `api/history.ts:77,95`, `api/leaderboard.ts:44`, `api/tracker.ts:66`, `stores/checkpoints.ts:128,138,143,148`, `stores/sharing.ts:25,40`, `stores/peers.ts:79`.
- Re-typed a third time inside every test file (`src/client/test/api_tokens_test.dart`,
  `src/web/src/test/api-tokens.test.ts`, `src/server/test/api-tokens.test.ts`).

**Impact:** renaming a path in some but not all copies produces a runtime 404 on the phone, not a
build failure. `CLAUDE.md:60` makes the manual sync an explicit rule, which is the tell that it is not
mechanised.

**Fix:** make the Fastify route table (or `openapi.ts`) the single source: generate a Dart and a TS
path-constants file from it, generate the README table, and assert all three in one CI job so drift
becomes a build failure.

### A-5 · One Nominatim client per platform: one throttle, one cache grid, one address parser

**Kind:** `kind/duplicate` · **Area:** `area/client` `area/web` · **Priority:** medium · **Effort:** M

- The "one request per 1.1 s" rule is restated six times: `CLAUDE.md:70`, `docs/calendar-events.md:40`,
  `docs/web-app.md:83`, `src/web/src/lib/throttle.ts:18,33`,
  `src/client/lib/src/data/network/event_geocoder.dart:17`, `place_search_service.dart:15`.
- `event_geocoder.dart:13-105` and `src/web/src/lib/geocoder.ts:18-71` are parallel implementations of
  the same normalise/peek/resolve/negative-cache logic with different storage keys
  (`event_geocode_cache_v1` vs `legacytracker.eventGeocode.v1`).
- The cache grids already disagree: `tracking_location_street_label.dart:14` quantises at 5 decimals
  (~1 m) while `src/web/src/lib/streets.ts:38-40` uses 4 decimals (~11 m) with a comment explaining
  why — the phone spends an order of magnitude more quota for the same label.
- `streets.ts:17` states its parser is a hand port of `tracking_location_street_label.dart:37-51`.
- Web calls Nominatim a third time over: `lib/streets.ts:4` + `:100-113`, `lib/geocoder.ts:5` + `:56-60`,
  `lib/places.ts:3` + `:16-21` — same host literal in two files, each rebuilding
  `new URLSearchParams({format:'jsonv2',…})` and the same headers, and the host is absent from
  `src/web/src/config.ts:4-19`.

**Impact:** a host, param or user-agent change needs six edits; the shared OSM quota is defended per
implementation rather than globally, so the rule is already broken (see C-4).

**Fix:** one `NominatimClient` per platform owning throttle + 4-decimal cache key + `describeAddress`,
used by street labels, place search and event geocoding; move the host to `config.ts`; keep one shared
fixture corpus of `address` payloads both platforms test against.

### A-6 · Move the duplicated formatting rules to one spec with one fixture set

**Kind:** `kind/duplicate` · **Area:** `area/client` `area/web` · **Priority:** medium · **Effort:** S

- `src/client/lib/src/core/formatters.dart:3,22,33,41,48,56,61,72,76,86` and
  `src/web/src/lib/format.ts:2,15,26,31,38,52,66,69,74,79,87` declare eight identically named functions
  with the same doc comments — two implementations of one invisible spec.
- Already diverged, verified: `formatters.dart:34-37` truncates minutes
  (`d.inMinutes.remainder(60)`), `format.ts:80` **rounds** (`Math.max(1, Math.round(seconds/60))`) — a
  41-second trip reads `0m`→`1m` on one platform and differs at every boundary; and the weekday lists
  start on different days (`formatters.dart:66` Monday vs `format.ts:66` Sunday via `getDay()`), which
  makes an off-by-one rewrite latent.
- The m/s→km/h factor is open-coded in six client places (`speed_color.dart:21`,
  `session_replay_screen.dart:323`, `tracking_map_tab.dart:858`, plus models) and seven web ones
  (`TravelLeaderboard.vue:53-55`, `TripCard.vue:16`, `PersonDetail.vue:75-76,184`, `ReplayLayer.vue:304`,
  `PeersMap.vue:106`) with no `formatSpeed`.

**Fix:** write the rules once (`docs/formatting.md` plus one fixture table: input → expected string) and
have `src/client/test/formatters_test.dart` and a `src/web/src/test/format.test.ts` both assert against
the same fixtures. Keep two implementations, one expectation set. Add `formatSpeed`/`plural` to each.

### A-7 · Generate the shared domain model: radius bounds and `tracking_issues` are re-declared 3-4 times

**Kind:** `kind/duplicate` · **Area:** `area/repo` · **Priority:** medium · **Effort:** M

- Checkpoint radius bounds: `schema.sql:131` (`CHECK (10 AND 250)`) ·
  `checkpoint.dart:3,4` (`minCheckpointRadiusM`/`max`) · `src/web/src/stores/checkpoints.ts:17,18`
  (`MIN_RADIUS_M`/`MAX_RADIUS_M`) · `openapi.ts:1428,1449` (`minimum: 10`, `maximum: 250`).
- Same concept, three field-name dialects: JSON `radius_m` → Dart `radiusM` (`checkpoint.dart:36`) vs
  web `radius` (`checkpoints.ts:44`); `canEdit` vs `can_edit`.
- The "smallest radius wins" tie-break is implemented three times: `checkpoint.dart:46-62`,
  `checkpoints.ts:60-70`, `src/server/src/services/checkpoints.ts:120-145`.
- The `tracking_issues` closed set in four: `src/server/src/services/tracking-issues.ts:11-19`,
  `tracking_issue.dart:6-10`, `src/web/src/lib/tracking-issues.ts:7-11`,
  `android/.../tracking/TrackingIssues.kt:29-38`.
- Three haversine implementations with two earth radii in the web package alone:
  `lib/replay.ts:81-90` (6 371 000), `lib/clusters.ts:49-58` (6371008.8), `lib/geo.ts:49` (6 371 008.8),
  both in active use (`stores/checkpoints.ts:4,67` vs `PersonDetail.vue:11,43`).

**Impact:** the boundary case that decides "is this point inside this place" differs by ~1.4 m between
two web files and can disagree with the phone at radii of 10–250 m.

**Fix:** generate Dart enums/TS types and the numeric bounds from the OpenAPI document, assert the SQL
`CHECK` matches it in a server test, and keep one `haversine` with one `EARTH_RADIUS_M` per package.

### A-8 · Theme and palette tokens are hand-copied between the web CSS and the Flutter theme

**Kind:** `kind/duplicate` · **Area:** `area/repo` · **Priority:** medium · **Effort:** L

- `src/web/src/style.css:41-82,90-94,129-160,…` (~31 `--color-*` tokens per `data-theme` block),
  `src/web/src/theme/themes.ts:26-70` whose own comment at `:25` says "Keep the previews in sync with
  the `data-theme` blocks", `src/client/lib/src/core/theme.dart:69-166` (same preview values, e.g.
  `0xFF1E1E2E/0xFF313244/0xFFCBA6F7` at `:112-115` vs `themes.ts:48`), and `theme.dart:405-548`
  `_CatppuccinPalette` re-typing the same ramps (`:452-454` vs `style.css:131-133`).
- `src/client/lib/src/core/palette.dart:5-77` and `src/web/src/lib/palette.ts:7-18` each self-declare
  that they "carry the same values" (`palette.dart:5`, `palette.ts:4`).
- `src/web/src/test/contrast.test.ts:8-27` parses `style.css`, so web-vs-web drift is caught. Nothing
  checks Flutter against either.

**Fix:** one checked-in token source (`src/shared/tokens.json`) feeding a build step for the CSS custom
properties, the Dart `ThemeData` and both preview lists; delete the hand-copied hexes.

### A-9 · Live-mode and Mapbox token constants are duplicated across the wire boundary

**Kind:** `kind/duplicate` · **Area:** `area/repo` · **Priority:** medium · **Effort:** M

- Live mode: `src/server/src/app.ts:188-190` (`LIVE_TTL_SECONDS = 600`, 4-minute renew, 45 s
  off-debounce) → `services/fcm-service.ts:52-53` (`lt_cmd`, `lt_ttl`) → decoded independently in
  `android/.../Receivers.kt:68,74` and `ios/Runner/TrackingEngine.swift:965-966`; the vocabulary is
  restated at `src/server/README.md:257` and `docs/location-tracking.md:134,248`.
- Mapbox: `3300` + `300` appear as defaults in `mapbox_token_service.dart:16-17` and in
  `src/server/src/services/mapbox-tokens.ts:15-17` (`DEFAULT_TTL_SECONDS = 55*60`,
  `DEFAULT_REFRESH_MARGIN_SECONDS = 5*60`), then again in `src/server/.env.example:35`, in
  `README.md:194`, and in `src/server/test/mapbox-tokens.test.ts:26-27`.
- `3.44.0`/Java version pins also duplicate across `mise.toml:4-6`, `ci.yml` (four places) and
  `release-android.yml:122,243` — see A-2.

**Impact:** the refresh margin is a contract — the app must refresh no later than the server rotates —
yet either side can change it alone and nothing notices.

**Fix:** return the effective `ttl_seconds`/`refresh_margin_seconds` in the
`POST /api/v1/mapbox/token` response and drop the client's hard-coded defaults; keep the command
vocabulary in one `docs/wire-protocol.md` table the README and both engines reference.

### A-10 · Read service endpoints from one place; stop hard-coding production URLs

**Kind:** `kind/duplicate` · **Area:** `area/client` · **Priority:** medium · **Effort:** S

- `src/client/lib/src/features/tracking/widgets/user_avatar.dart:61` builds
  `'https://auth.legacy-group.tech/auth/profile-picture/$userId'` as a literal, while
  `src/web/src/lib/avatars.ts:69` uses `${config.authUrl}` and `constants.dart:19` already exposes an
  overridable `authBaseUrl`. Verified.
- So a debug run with `--dart-define=AUTH_URL=http://10.0.2.2:4000` (documented at `CLAUDE.md:44`)
  signs in against the local OP but silently reads avatars from production.
- The same production hosts are re-typed at `constants.dart:5,18,35,43`, `src/web/src/config.ts:5,7,10,12`,
  `src/server/src/app.ts:86-87`, `auth_service.dart:49`, `openapi.ts:137` and `test-location.mjs:5-6`.
- `CLAUDE.md:71` admits one manual-sync site: `AppConstants.calendarWebUrl` (`constants.dart:43-46`) vs
  `src/web/src/config.ts:12`.

**Fix:** one `ServiceEndpoints` source consumed by both clients (JSON under `src/`, or the OpenAPI
`servers` block), plus a test asserting every URL in the app resolves through `AppConstants`.

### A-11 · Single-source the release tag pattern and the build-number comparison

**Kind:** `kind/duplicate` · **Area:** `area/repo` · **Priority:** medium · **Effort:** M

- Tag pattern in three executable places: `src/server/src/services/app-releases.ts:23`
  (`/^android-v(.+)\+(\d+)$/`), `scripts/release-android.sh:63` (constructs it) and `:66` (a second
  regex inside a `jq select(test(...))`); prose copies at `CLAUDE.md:51,61` and `README.md:206`.
- "Only a higher build number installs" re-implemented four times: `app-releases.ts:97`,
  `release-android.sh:67`, `AppUpdater.kt:132`, `app_updater.dart:153`.
- The default repo slug `Legacy-xForce/legacytracker` duplicated at `app.ts:207` and
  `release-android.sh:30`.

**Impact:** the release feed and the script that feeds it can disagree about the tag shape, which is a
silent no-update-for-everyone failure.

**Fix:** one `scripts/release-version.sh` (or a shared file) owning the pattern and the comparison,
sourced by the script, with a server unit test running the pattern against the script's own output.

### A-12 · The OpenAPI document omits `tracking_issues`; five env vars are undocumented

**Kind:** `kind/drift` `docs` · **Area:** `area/web` `area/server` · **Priority:** high · **Effort:** S

- `src/web/src/lib/openapi.ts:1296-1326` — `LocationSample` ends at `is_charging`; **no
  `tracking_issues`**, although the server accepts it (`services/tracking-issues.ts:11-19`), the
  README documents it (`README.md:236-244`), and both native engines send it (`Uploader.kt:71`,
  `TrackingEngine.swift:694`). The document's own `RosterEntry` does list it (`openapi.ts:1281`) and
  its example sets it (`openapi.ts:21`).
- `README.md:257` states the FCM command vocabulary is `"live" | "idle"`; `refresh` also exists
  (`services/fcm-service.ts:80`) and is documented only in `docs/location-tracking.md:184,248`.
- `/health` is served (`app.ts:2346`) and is the container healthcheck (`Dockerfile:18`) but appears in
  neither the README API reference nor the OpenAPI document.
- `src/server/.env.example` omits five variables the code reads: `LOG_LEVEL` (`app.ts:141`),
  `LOG_COLOR` (`:145`), `ANDROID_RELEASES_REPO` (`:206`, empty string disables the whole update feed),
  `GITHUB_TOKEN` (`:400`), and `ANDROID_MIN_SUPPORTED_CODE` (`:101` — the Phase-4 kill switch that
  forces app updates). Verified by reading `.env.example` and each call site.
- `src/web/.env.example` omits `VITE_OIDC_CLIENT_ID`, read at `config.ts:9` and declared at
  `env.d.ts:6`, while `CLAUDE.md:36` and `docs/web-app.md:130` list the other overrides without it.

**Impact:** the public `/docs` page under-describes the ingest contract that both apps actually post,
and the two switches that change production behaviour exist only in source.

**Fix:** add the missing schema entries and endpoints to `openapi.ts`, the `refresh` command to
`README.md:257`, and the six variables to the two `.env.example` files with one-line comments. Then a
test walking Fastify's printed route table asserting each route appears in `openapi.ts` and the README —
`CLAUDE.md:60` already requires the sync, so enforce it.

### A-13 · `docs/oidc-migration.md` still describes pre-migration code and a rollback that does not exist

**Kind:** `kind/drift` `docs` · **Area:** `area/repo` · **Priority:** medium · **Effort:** S

- `docs/oidc-migration.md:1-13` — "Status (2026-10-22): Phase 1 … committed on `oidc-migration`;
  Phase 3 (app) written but uncommitted … Phase 4 open", though the migration has shipped
  (`CLAUDE.md:59`, `README.md:5`).
- `:17-18` describes in the present tense code that is gone: `views/AccessDeniedView.vue`, the
  `login_screen.dart` form, `passkey_client.dart`, `attestation.dart`, `access_denied_screen.dart`,
  `passkeys_screen.dart`, the `passkeys` pub package — none exist in the tree or `pubspec.yaml`.
- `:193` and `:265` offer `VITE_AUTH_MODE=legacy` as a rollback; that variable appears nowhere in
  `src/web`.
- `:185` still instructs deleting `AccountDisabledError`, which is live and used by the OIDC path too
  (`src/web/src/api/auth.ts:28,81`).

**Impact:** the document that gates the Phase-4 cleanup — the one that decides which legacy auth
branches may be deleted (see B-6) — is not trustworthy, so the cleanup stalls or cuts the wrong branch.

**Fix:** rewrite the header to "shipped; remaining: Phase 4" with an explicit file:line list of the
still-live legacy branches, drop the `VITE_AUTH_MODE` rollback, and move deleted-file history out of
"Where we are".

### A-14 · `test-location.mjs` uses the retired password login and defaults to production

**Kind:** `kind/dead-code` · **Area:** `area/repo` · **Priority:** high · **Effort:** S

Verified directly:

- `test-location.mjs:6` — `DEFAULT_SERVER = 'https://tracker.legacy-group.tech'`, and `:11` uses it
  whenever `--server` is omitted, which is exactly how `CLAUDE.md:49` documents the command. Running
  the documented one-liner writes fake history to the live PostGIS database and, per `CLAUDE.md:75`,
  triggers "go live" pushes to every registered phone.
- `:71-85` — authenticates with `POST ${AUTH_URL}/auth/login`, the legacy ROPC endpoint no client uses
  any more; `docs/oidc-migration.md:252` plans its removal, so the script stops working entirely at
  Phase 4.
- `:111` — embedded credentials `login('test1', 'test1')`.
- `:18-37` — the "GPS drive around central Turin" route is commented out; `:40` leaves a single
  waypoint (`43.78, 11.09`) mislabelled "Piazza Castello" — a one-off debug leftover, ~150 km from
  Turin.
- `:95` predates the `source` and `tracking_issues` fields; `:135` reads the deprecated
  `x-pacing-mode` header that `README.md:250-252` says only older builds use.

**Fix:** move it to `scripts/simulate-drive.mjs` with `--server` **required** (no production default)
and an `X-API-Token` argument instead of password login, restore the route, add
`source`/`tracking_issues` to the payload, and update `CLAUDE.md:49`. Delete it if a simulator is not
wanted.

### A-15 · Delete the second lockfile and the unused `cupertino_icons`

**Kind:** `kind/dead-code` · **Area:** `area/repo` · **Priority:** medium · **Effort:** S

- `src/server/bun.lock` (54 KB) is tracked alongside `src/server/package-lock.json` (113 KB) — verified
  with `git ls-files src/server`. Nothing consumes bun: not `src/server/Dockerfile` (`npm ci` twice),
  not `ci.yml`, not `mise.toml:18-24` (`npm run dev`, `npm test`). `CLAUDE.md:19` only notes the oddity.
- `src/client/pubspec.yaml:34` — `cupertino_icons: ^1.0.8`; zero imports of
  `package:cupertino_icons/` and zero `Cupertino` references in `lib/`, `test/`, `android/`, `ios/`
  (verified by grep). Pure Flutter-template leftover. `flutter_lints` is **not** dead — used at
  `analysis_options.yaml:16`.

**Fix:** `git rm src/server/bun.lock`; delete the `cupertino_icons` line.

### A-16 · The uncommitted `mise.toml` change drops the Flutter pin that README and CI still rely on

**Kind:** `kind/drift` · **Area:** `area/repo` · **Priority:** medium · **Effort:** S

- `git diff mise.toml` — the tracked line `flutter = "3.44.0"   # matches CI; brings Dart 3.12` is
  removed in the working tree and is the only uncommitted change in the repo besides `.qoder/`.
- `README.md:55` still documents `mise install # node 22, java 21, flutter 3.44`; `mise.toml:34-46`
  still runs `flutter analyze|test` and `./gradlew`; `ci.yml` pins `3.44.0` in four places.
- Consequence if committed as-is: `mise` hands out whatever Flutter is on the machine, so local
  `flutter analyze` results stop matching CI — the exact drift the comment was guarding.

**Fix:** decide explicitly. Either revert the line, or land the removal together with a single
`FLUTTER_VERSION` variable consumed by `mise.toml`, the four `ci.yml` pins, `README.md:55` and
`CLAUDE.md:38`. Do not commit it silently alongside unrelated work.

## B. Server (`src/server`)

### B-1 · Leaderboard runs one unbounded query per user, serially

**Kind:** `kind/perf` · **Area:** `area/server` · **Priority:** high · **Effort:** M

Verified directly:

- `src/server/src/app.ts:2074-2076` — `SELECT id, name FROM users`, no `LIMIT`: every registered user.
- `app.ts:2080-2092` — `for (const user of users.rows) { … await pool.query(…) }`: one PostGIS query per
  user, awaited serially, so wall clock is N round trips. The comment at `:2078-2079` explains it
  bounds *memory*, not fan-out.
- `app.ts:2093-2105` — each user's whole point set for the window (up to 366 days,
  `MAX_LEADERBOARD_WINDOW_MS` at `app.ts:183`) is materialised in JS and passed to `summarizeTravel`
  (`services/leaderboard.ts:23`), which re-runs `buildSessions` over it.
- `src/server/src/config/db.ts:7` — pool `max: 10`.
- Called by both clients: `leaderboard_service.dart:30`, `src/web/src/api/leaderboard.ts:44`.

**Impact:** the slowest endpoint in the API, and its cost grows with total registered users rather than
with the requested range.

**Fix:** one set-based query (`WHERE user_id = ANY($1)` … `ORDER BY user_id, recorded_at`), partition
rows by `user_id` in JS, keep the per-user session heuristic in memory or push it into SQL window
functions; add a short-TTL cache keyed on the rounded range.

### B-2 · Batch dwell seeding fires the heaviest query once per visible user

**Kind:** `kind/perf` · **Area:** `area/server` · **Priority:** high · **Effort:** M

- `app.ts:1175-1182` — `Promise.all(visible.map(row => getDwell(row.id)))`.
- `app.ts:1011-1033` — `getDwell` misses the in-memory map for every user not yet seen and runs
  `DWELL_SEED_SQL`.
- `services/dwell-tracker.ts:107-131` — that SQL uses a `LEFT JOIN LATERAL` applying
  `ST_DWithin`/speed/`source` predicates **per row** back to the last "away" point, plus a `min()`
  subselect. A user parked for weeks walks a long stretch of the
  `(user_id, recorded_at DESC)` index (`db/schema.sql:114`); nothing indexes the `away` predicate.
- Reached on hot paths: `app.ts:2331` (every WebSocket open), `:1270`, `:1316`.

**Impact:** the first snapshot after a boot issues N of the heaviest queries in the codebase at once
against a 10-slot pool, stalling location ingest behind it.

**Fix:** seed the whole roster in one query (`FROM unnest($ids) AS u(user_id) CROSS JOIN LATERAL …`)
and bound the lateral scan (`AND a.recorded_at > l.recorded_at - INTERVAL '90 days'`) so an old stay
cannot become a full-history scan.

### B-3 · WebSocket fanout re-serializes the identical payload once per viewer

**Kind:** `kind/perf` · **Area:** `area/server` · **Priority:** medium · **Effort:** S

Verified directly:

- `services/connection-manager.ts:100-105` — `broadcastEach` calls `JSON.stringify(message)` **inside**
  the per-viewer loop.
- `services/sharing.ts:61-67` — `messageFor` returns the *same* object reference for every viewer who
  may see it, so all those stringifies produce the same bytes.
- `app.ts:1125` — this runs for every ingested point, i.e. every few seconds per driver while live.

**Impact:** with V viewers each upload performs V identical serializations plus V encodes — pure CPU on
the ingest hot path, scaling linearly with audience size.

**Fix:** memoize by object identity in `broadcastEach` (`WeakMap` or compare against the previous
reference) and group sockets by visibility class so one string goes out per distinct payload.

### B-4 · Two hot-path queries on `user_fcm_tokens` have no supporting index

**Kind:** `kind/perf` · **Area:** `area/server` · **Priority:** medium · **Effort:** S

- `app.ts:321` and `app.ts:360` — `DELETE FROM user_fcm_tokens WHERE token = ANY($1)`.
- `db/schema.sql:19-24` — the PK is `(user_id, token)`; `token` alone is not indexed, so the leading
  column is missing and each prune is a sequential scan of the table.
- `app.ts:315-318` — the paired `SELECT token FROM user_fcm_tokens` (no `LIMIT`) runs on every
  live/idle transition and on every 4-minute renewal (`app.ts:189`, `:444-446`, `:423`).

**Fix:** `CREATE INDEX IF NOT EXISTS user_fcm_tokens_token_idx ON user_fcm_tokens (token);` in
`schema.sql` (and in `ensureBackendSchema()`), and cache the token list in `pushToAllDevices` with a
short TTL so renewals stop re-reading the whole table.

### B-5 · Identity, scope, route-label and error-mapping boilerplate is re-typed in 25 handlers

**Kind:** `kind/duplicate` · **Area:** `area/server` · **Priority:** medium · **Effort:** M

- The identical 4-line block `identity = await …(); if (!identity.ok) return rejectRequest(request,
  reply, "<route literal>", identity);` at `app.ts:1223,1231,1285,1321,1347,1399,1427,1473,1509,1561,
  1581,1609,1657,1691,1709,1718,1749,1769,1795,1818,1879,1905,1958,2061,2140` — ~100 redundant lines,
  with the route pattern re-typed as a string (`:1233`, `:1284`, `:1690`, `:1708`, …) and inconsistent
  inline-vs-`const route` style.
- Mobile-client guard duplicated verbatim: `app.ts:1431-1439` and `:1477-1485` (9 lines each).
- "Unknown user" existence check duplicated: `app.ts:1245-1251` and `:1290-1296`.
- Checkpoint 403-vs-404 re-probe duplicated: `app.ts:1648-1653` and `:1679-1684`, with
  `SELECT 1 FROM checkpoints WHERE id = $1` also at `:1648`.
- Profile `SELECT id, name, avatar_url, role` plus identical response shaping twice:
  `app.ts:1328-1343` and `:1384-1395`.
- `isUniqueViolation`/`22P02` mapping hand-written in three variants: `app.ts:1600-1605`,
  `:1638-1646`, `:1673-1678`.

**Impact:** every new route re-derives auth, scope, route label and error mapping by hand — and the
divergence risk sits exactly where the credential-minting guards live.

**Fix:** a `preHandler` (or a `withIdentity(request, reply, opts, fn)` helper) that resolves identity,
attaches it to the request, logs with `request.routeOptions.url` instead of a literal, and takes the
mobile-only restriction as an option; extract `profileRow()` and `checkpointOutcome()` helpers and one
`mapDbError()`.

### B-6 · Legacy auth compatibility branches: three are already redundant and none says when it can go

**Kind:** `kind/dead-code` · **Area:** `area/server` · **Priority:** medium · **Effort:** S

- `services/access-token.ts:160-182` — accepts non-`at+jwt` tokens via `payload.type === "access"` +
  `hasTrackerScope` (`services/tracker-scope.ts:9`). **Still has dependents**: pre-OIDC app/web builds;
  `docs/oidc-migration.md` Phase 4 gates removal on raising `min_supported_code`. Keep.
- `app.ts:1431` and `:1477` — `identity.clientId !== null &&` exempts legacy-shaped tokens from the
  mobile-only restriction on `/api/v1/mapbox/token` and `/api/v1/devices`, i.e. the issue-36 hole stays
  open for exactly the token class Phase 4 removes. **Removable at Phase 4 by dropping the `!== null`.**
- `app.ts:648-651` — `purgeApiTokens` on a scope-less legacy JWT, already duplicated by the OP signal
  at `:2203-2205`. **Removable.**
- `services/fcm-service.ts:55` — the `pacing` data field, commented "read by older app builds". No
  reader anywhere: `Receivers.kt:68,74` reads only `lt_cmd`/`lt_ttl`; no Dart, Swift or web reader.
  **Removable once `min_supported_code` passes those builds.**
- `app.ts:212-217,440-442,1944-1945,1952` — `PacingMode`/`getPacingMode`/`X-Pacing-Mode`. The only
  consumer in the repo is the dev simulator `test-location.mjs:135`. Also a live contract bug:
  `src/web/src/lib/openapi.ts:1336` declares `enum: ['PASSIVE','ACTIVE']` while the server emits
  `AGGRESSIVE`. **Removable** (or fix the enum if kept).

**Fix:** keep the `access-token.ts` shape until Phase 4; now drop the `clientId !== null` escape on the
two minting routes and the redundant purge branch; add a one-line
`// Phase 4 (docs/oidc-migration.md): delete with the legacy token branch` marker on each survivor;
delete `PacingMode`/`X-Pacing-Mode`/FCM `pacing` behind the raised minimum. Depends on A-13 (the
migration doc must list these sites first).

### B-7 · Dead WebSocket branch lets a read-only ticket reach location ingest

**Kind:** `kind/dead-code` · **Area:** `area/server` · **Priority:** low · **Effort:** S

- `app.ts:2307-2320` — parses and ingests an inbound `{type:"location"}` message; its own comment calls
  it the "Legacy path".
- No client sends it: `src/web/src/api/stream.ts:137` and `remote_backend.dart:92` send only
  `map_active`; no other `.send(` exists in either realtime client.
- `src/server/README.md:319-321` documents `map_active` as the only client→server message;
  `test-location.mjs:95` uploads over HTTP. No test imports `app.ts`, so nothing covers the branch.

**Impact:** dead code in the security-sensitive socket handler — it is the one path where a
read-only ticket can still reach ingest logic, silently widening what a validated ticket may do.

**Fix:** delete the branch and ignore unknown `type` values, then re-check whether the `readOnly` flag
still needs to gate anything.

### B-8 · `viewer_state` is written on every socket event and read by nothing

**Kind:** `kind/dead-code` · **Area:** `area/server` · **Priority:** medium · **Effort:** S

Verified directly: the only hits for `viewer_state` repo-wide are `db/schema.sql:92` (the table) and
`app.ts:449` (the insert). No `SELECT` in `src/server/src`, `src/web/src`, `src/client/lib`, `docs/` or
`README.md`.

- `app.ts:448-457` — upsert inside `updateViewerState()`, called from the WebSocket
  connect/close/`map_active` paths (`app.ts:2271`, `:2303`, `:2328`).
- Live mode and the viewer list both read `ConnectionManager` in memory
  (`services/live-controller.ts:39`, `app.ts:387-395`).
- Related bug in the same call sites: `updateViewerState()` is invoked without `await` at `:2271` and
  `:2328`, so a throw from `liveController.update` becomes an unhandled rejection.

**Fix:** drop the upsert and the table. If it was meant as a restart-safe or multi-instance counter,
read it back in `buildSnapshot`/`/health` and debounce the write instead — and `await` it either way.

### B-9 · Unbounded in-memory maps: expired tickets and negative credential caches are never swept

**Kind:** `kind/perf` · **Area:** `area/server` · **Priority:** medium · **Effort:** S

Verified directly:

- `app.ts:169`, `:1886` — `tickets.set(...)` with `expiresAt = now + 60s`.
- `app.ts:2236-2258` — the rejection branch (`unknown ticket` / `already used` / `expired`) logs, closes
  the socket and `return`s **without** `tickets.delete`; the only delete is the success path at `:2261`.
  Every expired-but-never-redeemed ticket stays forever.
- `services/api-tokens.ts:385`, `:568-571` — `cache` keyed by `sha256(token)`; negative lookups for any
  header matching `isApiTokenShape` (`:112-118`) are stored and never swept.
- `services/device-auth.ts:36`, `:96-99` — same pattern for `Authorization: Device`.
- Minting is frequent by design: `app.ts:190` (45 s off-debounce) and the web requests a ticket on every
  tab focus (`src/web/src/api/stream.ts:137`).
- `services/connection-manager.ts:66` sweeps sockets; nothing sweeps tickets or credential caches.

**Impact:** slow unbounded memory growth proportional to rejected/forgotten credentials — a
long-running container never gives it back.

**Fix:** delete the entry in the rejection branch, add an expiry sweep to the existing heartbeat timer,
and give the two credential caches a size cap (evict past ~1000 entries) swept on the same tick.

### B-10 · `ensureBackendSchema()` restates `schema.sql`; 22 of its 24 statements are no-ops at boot

**Kind:** `kind/redundant` · **Area:** `area/server` · **Priority:** medium · **Effort:** M

- `app.ts:736-884` — 24 sequential DDL statements at every container start. 22 recreate what
  `db/schema.sql:1-153` already defines: the five `ALTER … ADD COLUMN` on `users` (`:737-750` vs
  `schema.sql:3-17`), `location_history` `source`/`accuracy` (`:751-756` vs `:105-110`), `api_tokens`
  `allowed_ips`/`deleted` (`:818-823` vs `:57,61`), and every `CREATE TABLE`/`CREATE INDEX` for
  `devices`, `checkpoints`, `location_share_blocks`, `api_tokens`, `api_token_requests`,
  `location_history_user_recorded_uniq`.
- Genuinely only-it-can-do: the FK `confdeltype` `DO` block (`:849-865`) and the duplicate-row
  collapse (`:869-875`).
- Drift proof: `ensureBackendSchema` never creates `users`, `location_history`, `user_fcm_tokens` or
  `viewer_state`, yet `schema.sql` never carries the `ON DELETE CASCADE` fix — neither file alone is
  authoritative.

**Impact:** 22 pointless round trips per start, and the one migration that matters is invisible among
the noise. Any new column also has to be written twice.

**Fix:** reduce `ensureBackendSchema()` to the FK conversion and the dedupe+unique-index statements;
make `schema.sql` the complete source of truth applied behind a version check rather than re-run each
boot (and fold B-4's new index into it properly).

### B-11 · `/api/v1/history` caps time but not rows

**Kind:** `kind/perf` · **Area:** `area/server` · **Priority:** medium · **Effort:** M

- `app.ts:1995-2004` — `SELECT … WHERE user_id AND recorded_at BETWEEN … ORDER BY recorded_at ASC` with
  no `LIMIT`.
- `app.ts:176-180` — 7-day default, 30-day cap with points, 93-day cap without.
- `app.ts:2034-2051` — every point of every session is re-serialized into the response even when the
  caller passed `points=false` and only wants summaries; `buildSessions`
  (`services/session-builder.ts:113`) holds them all in memory.

**Impact:** the bound is temporal, not volumetric — a month of dense `move` points is one unbounded JSON
response and one unbounded JS array, on the route both clients use for replay.

**Fix:** apply a `MAX_HISTORY_ROWS` `LIMIT` with a `truncated` flag, and project the SQL columns
conditionally so `ST_X`/`ST_Y` are skipped when `points=false`.

### B-12 · `api_token_requests` is the highest-write table and nothing bounds it

**Kind:** `kind/perf` · **Area:** `area/server` · **Priority:** medium · **Effort:** S

- `app.ts:286-309` — one insert per token-bearing request from the `onResponse` hook, refusals included.
- `services/api-token-requests.ts:93-110` — single-row insert; `DELETE FROM api_token_requests` appears
  nowhere in the repo, so there is no retention.
- `services/api-token-requests.ts:122-137` — `listForToken` runs a separate
  `SELECT 1 FROM api_tokens … NOT deleted` before the page query: two round trips where one `JOIN`
  gives the same 404 signal.
- Indexes are correct (`schema.sql:86-90` covers `(token_id, id DESC)` and `(user_id, created_at DESC)`),
  so this is retention and read-shape, not missing indexes.

**Fix:** merge the existence probe into the page query via `JOIN api_tokens t ON t.id = … AND NOT t.deleted`,
and add a retention step (e.g. keep 90 days) driven from the existing startup or heartbeat timer.

### B-13 · Three haversine copies server-side, one of them only reachable from tests

**Kind:** `kind/dead-code` · **Area:** `area/server` · **Priority:** low · **Effort:** S

Verified directly: `resolveCheckpoint`, `ResolvableCheckpoint` and the exported `haversineMeters` in
`services/checkpoints.ts:90-145` are referenced only by `test/checkpoints.test.ts:6-8,72-101`;
`app.ts:25-28` imports just `canModifyCheckpoint` and `validateCheckpointInput`. Meanwhile the same
formula exists privately at `services/dwell-tracker.ts:40-53` and `services/session-builder.ts:40-50`,
and the feature is reimplemented per client (`checkpoint.dart:48`, which comments that it "mirrors the
server's `resolveCheckpoint`", and `src/web/src/stores/checkpoints.ts:63`).

**Impact:** the "authoritative" server copy is the one nobody calls, and three copies of one formula in
one package is how boundary decisions start to disagree.

**Fix:** delete `ResolvableCheckpoint`/`resolveCheckpoint`/the exported `haversineMeters` and their
tests; keep one great-circle helper in `services/geo.ts` used by `dwell-tracker` and `session-builder`.
Coordinate with A-7 so the client and web copies come from one spec.

### B-14 · Server runtime and README layout have drifted from the code

**Kind:** `kind/drift` · **Area:** `area/server` · **Priority:** low · **Effort:** S

- `Dockerfile:1,8` pin `node:18-alpine` while `package.json:13` says `engines.node >= 18` and CI uses
  Node 22 (`ci.yml:89-105`) — the shipped runtime trails CI by a major version.
- `README.md:341-355` lists 10 files under `src/` and omits 11 that exist: `access-token.ts`,
  `app-releases.ts`, `checkpoints.ts`, `client-address.ts`, `display-name.ts`, `mapbox-tokens.ts`,
  `sharing.ts`, `tracker-scope.ts`, `tracking-issues.ts`, `viewer-presence.ts` (and `connection-manager.ts`
  is listed, so the map is a mix rather than a stale snapshot).

**Fix:** align the Docker base image with CI's Node, and generate the README file list or trim it to
directories only.

## C. Flutter client (`src/client/lib`)

### C-1 · Extract one `ApiClient` from the seven network services

**Kind:** `kind/duplicate` · **Area:** `area/client` · **Priority:** high · **Effort:** M

Roughly 150 of ~1100 network lines are copy-paste:

- `_headers` identical three times (`api_token_service.dart:219-222`, `checkpoint_service.dart:88-91`,
  `sharing_service.dart:61-64`) plus three inline copies (`device_service.dart:42-45`,
  `profile_service.dart:65-68`, `remote_backend.dart:70-73`).
- `_send` (try / 15 s timeout / one Exception) byte-identical in three files:
  `api_token_service.dart:224-232`, `checkpoint_service.dart:101-109`, `sharing_service.dart:66-74`.
- `_check` status-switch three times: `api_token_service.dart:234-250`,
  `checkpoint_service.dart:111-130`, `sharing_service.dart:76-86`.
- "read `body['error']` if JSON else null" four times: `api_token_service.dart:252-259`,
  `checkpoint_service.dart:132-139`, `location_refresh_service.dart:66-73`, `auth_service.dart:86-94`.
- `_uri`/`_apiUri` (`baseUri.replace(path:)`) five times: `api_token_service.dart:214`,
  `checkpoint_service.dart:86`, `profile_service.dart:91`, `history_service.dart:97`,
  `remote_backend.dart:347`.
- Same timeout + `onTimeout` block four times: `history_service.dart:40-47`, `:81-88`,
  `profile_service.dart:18-25`, `leaderboard_service.dart:32-41`.
- The literal `'Unable to reach the server. Check your connection and try again.'` eight times across
  seven files.
- Seven near-identical "user-safe message" exception classes: `api_token_service.dart:8-15`,
  `checkpoint_service.dart:8-18`, `sharing_service.dart:6-13`, `location_refresh_service.dart:6-18`,
  `calendar_service.dart:7-18`, `auth_service.dart:9-16,19-29`.
- The CLAUDE.md content-type rule is already applied inconsistently as a consequence:
  `checkpoint_service.dart:88` sends `Content-Type` on a body-less GET/DELETE — which is exactly what
  makes Fastify answer 400 — while `mapbox_token_service.dart:66-68` deliberately does not.

**Fix:** one `ApiClient` (baseUri + `getAccessToken` callback + a single injected `http.Client`)
exposing `getJson/postJson/patchJson/deleteJson` with the timeout, header and status→error rules in one
place, and one `ApiException(message, {status})` replacing the seven classes. This also closes C-8 and
C-14.

### C-2 · Every location fix rebuilds all three bottom tabs

**Kind:** `kind/perf` · **Area:** `area/client` · **Priority:** high · **Effort:** M

- `features/tracking/tracking_controller.dart:354` — `notifyListeners()` inside the engine's `'location'`
  handler, i.e. per fix; also `:48`/`:52` per peer/viewer push and `:425` per battery poll. Verified.
- `features/tracking/tracking_screen.dart:135-176` — one `Consumer2<TrackingController, MapSettings>`
  wraps the whole `IndexedStack`, so `TravelTab` (`:167`) and `TrackingProfileTab` (`:174`) rebuild on
  every notification while consuming none of that data.
- `tracking_screen.dart:64-66` — a 1-minute `Timer` `setState`s the same tree solely to re-resolve the
  Auto map preset.
- `features/travel/travel_tab.dart:234-247` — eager `ListView(children: [for (final entry in entries)
  _EntryCard(…)])`, so a whole leaderboard repaints per notification.

**Impact:** the map is correctly insulated by `MapScene`, but the rest of the screen is not — the profile
cards and the leaderboard repaint once a second while driving, which is the exact cost class the scene
was introduced to remove.

**Fix:** narrow the subscription: give each tab its own `Consumer`/`Selector` on just `peers` or
`selfProfile`, lift the Auto-preset timer into a leaf widget, and convert `TravelTab` to
`ListView.builder`.

### C-3 · Collapse the three API-token screens' copy-pasted building blocks

**Kind:** `kind/duplicate` · **Area:** `area/client` · **Priority:** high · **Effort:** M

These three files total 903 + 346 + 364 lines, of which ~200 are the same five widgets re-declared per
file:

- `_Notice` byte-identical three times: `features/auth/api_tokens_screen.dart:879-903`,
  `api_tokens_audit_screen.dart:322-346`, `api_token_requests_screen.dart:340-364`.
- `_Badge` twice: `api_tokens_audit_screen.dart:294-320`, `api_token_requests_screen.dart:308-338`
  (differ only in `vertical:` 1 vs 2 and a monospace tweak).
- The token row column (name / WRITE badge / hint / created / allowed-IPs) twice:
  `api_tokens_screen.dart:602-665`, `api_tokens_audit_screen.dart:226-279` (~54 lines each).
- The 40 px circle-icon + title + body intro card, three times: `api_tokens_screen.dart:423-479`,
  `api_tokens_audit_screen.dart:97-142`, `api_token_requests_screen.dart:115-180`.
- The identical load/error/`_loading` `setState` scaffolding: `api_tokens_screen.dart:53-71`,
  `api_tokens_audit_screen.dart:45-58`, `api_token_requests_screen.dart:53-74`.
- The uppercase `letterSpacing: 0.8` section label three times: `api_tokens_screen.dart:267-277`,
  `api_tokens_audit_screen.dart:169-179`, `tracking_profile_tab.dart:225-245`.
- `api_token_requests_screen.dart:207-211` — `ListView(children:)` with a full builder per request, on a
  list that grows unboundedly via "Load older".

**Impact:** a token row and its audit twin already render slightly differently, and every style change
must be made three times.

**Fix:** move `Notice`, `Badge`, `SectionLabel`, `IntroCard` and
`ApiTokenRow(token, {actions})` into `features/auth/widgets/`, and back the requests list with a
paginated `ListView.builder`.

### C-4 · Street labels issue unthrottled Nominatim requests from an unbounded cache

**Kind:** `kind/perf` · **Area:** `area/client` · **Priority:** high · **Effort:** M

Verified directly in `features/tracking/widgets/tracking_location_street_label.dart`:

- `:10` — `final Map<String, Future<String>> _streetLookupCache = {}`, never evicted; repo-wide only
  `:10` and `:15` touch it.
- `:13-15` — the key is lat/lng at 5 decimals (~1 m), so every GPS fix of every visible peer is a new
  key.
- `:17-29` — a raw top-level `http.get` to `nominatim.openstreetmap.org/reverse` with no delay, no
  timeout and no shared client, bypassing the 1.1 s spacing and persisted cache that
  `data/network/event_geocoder.dart:67-72` implements.
- Call sites sit in per-fix rebuild paths: `tracking_users_drawer.dart:789`, `:1142`,
  `location_history_screen.dart:811,822`.

**Impact:** while anyone in the list is moving the UI issues roughly one reverse geocode per fix per
visible row against OSM's documented one-request-per-second policy, and retains every answer for the
app's lifetime. `CLAUDE.md:70` states Nominatim is shared and throttled; this path is the exception.
See A-5 for the cross-package side.

**Fix:** snap the key to a coarse grid (or keep the label until the point moves >50 m), route the call
through the shared throttled queue, add a timeout, and bound the map with an LRU.

### C-5 · `ProfileService` parses the same profile twice

**Kind:** `kind/duplicate` · **Area:** `area/client` · **Priority:** medium · **Effort:** S

- `data/network/profile_service.dart:32-43` and `:77-88` — 12 verbatim lines building a `UserProfile`
  from `data[…]`.
- `:27-29` and `:72-74` — identical `!= 200 → throw Exception('Unable to …: ${response.body}')`.
- The same field mapping happens a third time from the stream at `remote_backend.dart:249-330`.

**Impact:** any new profile field (`sharing`, `here_since`, …) must be added in two places, and forgetting
one silently loses it after a profile edit.

**Fix:** one `UserProfile.fromJson`, used by both call sites and by `_handlePeerUpdate`.

### C-6 · A whole `RemoteBackend` is constructed to send one FCM POST, and its listener leaks

**Kind:** `kind/redundant` · **Area:** `area/client` · **Priority:** medium · **Effort:** S

- `lib/app.dart:235-241` — a `RemoteBackend` (one `http.Client`, two broadcast `StreamController`s,
  WebSocket and reconnect state) is built only to call `registerFcmToken`, then immediately disposed.
- `lib/app.dart:244-252` — the same again inside the `onTokenRefresh` listener. Verified: a third
  construction at `:265` is the legitimate one.
- `lib/app.dart:244` — the returned `StreamSubscription` is discarded and never cancelled;
  `_AuthenticatedAppState.dispose` (`:288-291`) does not cancel it. Re-authenticating creates another
  `AuthenticatedApp` and therefore another permanent listener.
- `remote_backend.dart:65-79` — `registerFcmToken` needs only `baseUrl` + bearer token, yet sits on the
  realtime `Backend` interface (`backend.dart:16`) where it does not belong.

**Fix:** move FCM registration to a one-line POST helper (or the new `ApiClient`), store the
subscription in a field and cancel it in `dispose()`, and drop the method from `Backend`.

### C-7 · `RemoteBackend` re-emits the entire roster for every single peer point

**Kind:** `kind/perf` · **Area:** `area/client` · **Priority:** medium · **Effort:** M

- `remote_backend.dart:331-334` — every peer update ends with
  `List<UserProfile>.unmodifiable(_peerCache.values.toList())` plus a controller `add`: O(roster)
  allocation and a full listener rebuild per single point.
- `remote_backend.dart:211-239` — one `jsonDecode` per frame; a `snapshot` fan-out (`:220`, `:241-247`)
  emits N separate full-list events back to back.
- `remote_backend.dart:288` — `profile.history = [point, …profile.history].take(20).toList()` re-copies a
  20-element list per update per peer (and the field is unread — see C-10).
- `remote_backend.dart:249-335` — `_handlePeerUpdate` is 87 lines of per-field
  `payload[…] as X? ?? profile.X` assignments.

**Impact:** with live mode on, the server broadcasts one point per moving peer per second, so cost
scales as roster² rather than per-peer, and downstream widgets rebuild on each. This is the client twin
of E-1.

**Fix:** buffer incoming updates and emit one consolidated list per frame (microtask flush or ~200 ms
coalescing); have `snapshot` populate `_peerCache` before a single `add`.

### C-8 · Services own `http.Client`s that nobody can close

**Kind:** `kind/perf` · **Area:** `area/client` · **Priority:** low · **Effort:** M

- Ten services do `_httpClient = httpClient ?? http.Client()` and expose no `close()`:
  `history_service.dart:17`, `checkpoint_service.dart:23`, `api_token_service.dart:33`,
  `sharing_service.dart:20`, `profile_service.dart:9`, `device_service.dart:28`,
  `leaderboard_service.dart:9`, `place_search_service.dart:18`, `calendar_service.dart:24`,
  `location_refresh_service.dart:24`. Only `remote_backend.dart:133` and
  `mapbox_token_service.dart:116` ever close theirs.
- Consequence at a call site: `tracking_users_drawer.dart:1054` builds a throwaway
  `HistoryService(baseUrl: baseUrl)` per refresh — a fresh client, no connection reuse, never closed.
- Serial I/O nearby that could be batched: `token_storage.dart:151-155` (5 sequential
  SharedPreferences writes), `:159-163` (5 removes), `device_service.dart:93-95` (3), `:99-101` (3).

**Fix:** inject one app-wide `http.Client` (C-1) instead of defaulting per service, and batch the prefs
writes with `Future.wait`.

### C-9 · `EventGeocoder` re-serializes its whole cache after every single lookup

**Kind:** `kind/perf` · **Area:** `area/client` · **Priority:** medium · **Effort:** S

- `data/network/event_geocoder.dart:77-78` — after each resolved place: store, then `await _save()`.
- `:97-105` — `_save` `jsonEncode`s **every** entry and does a SharedPreferences disk write.
- `:36` — `_cache` is never evicted; `:25` persists it forever under `event_geocode_cache_v1`.

**Impact:** N answers cost O(N²) serialization plus one disk write each, on the UI isolate; a
long-lived account pays more every month for the same feature. The web store has the same bug (E-8).

**Fix:** coalesce `_save()` behind a dirty flag flushed on a timer or on lifecycle change, and cap the
map with a few-hundred-entry LRU.

### C-10 · Dead `TrackingController` state, allocated on every fix

**Kind:** `kind/dead-code` · **Area:** `area/client` · **Priority:** medium · **Effort:** S

- `tracking_controller.dart:81-84` — `speedLabel`: only hit repo-wide is the definition.
- `:86-87` — `isMoving`: no reference; every `.isMoving` in the repo is `LocationPoint.isMoving` or
  `MarkerPerson.isMoving`.
- `:66,351,353` — `history` is written per fix (`history = [point, …history].take(40).toList()`, a fresh
  ~41-element allocation each time) and copied into `selfProfile.history`, but nothing reads
  `controller.history` or `UserProfile.history` (`data/models/user_model.dart:23`) anywhere in `lib/` or
  `test/`; `remote_backend.dart:288,323` and `mock_backend.dart:123-126` write the same unread field.
- Otherwise clean: every declared widget type and sheet path has a live caller, and the only mode
  branches are `kReleaseMode` (`core/constants.dart:11-46`, `mapbox_token_gate.dart:69`), both real.

**Fix:** delete `speedLabel`, `isMoving` and `history` from the controller, and the write-only
`UserProfile.history` field with its three assignment sites. Removes one list allocation per GPS fix on
the path C-2 already makes expensive.

### C-11 · Delete `MockBackend`; nothing constructs or imports it

**Kind:** `kind/dead-code` · **Area:** `area/client` · **Priority:** high · **Effort:** S

Verified directly: repo-wide, the only hits for `MockBackend` are inside
`src/client/lib/src/data/network/mock_backend.dart` (`:9` class, `:10` singleton, `:11` factory, `:61`
constructor) plus one mention in `CLAUDE.md:64`. No import anywhere in `lib/`, `test/`, `src/web`,
`src/server`, `scripts/` or `docs/`.

- `mock_backend.dart:96` — its `Timer.periodic` simulated-motion source could only ever start if the
  factory ran, so the feature has never executed.
- With it gone, `data/network/backend.dart:6-31` leaves `Backend` with exactly one implementation
  (`RemoteBackend`), never swapped in tests either.

**Impact:** 133 lines of unreachable fake realtime backend including a hard-coded peer roster, and the
sole justification for an abstraction that reviewers will read as a live seam.

**Fix:** delete the file. Keep `Backend` only if a fake is coming back; otherwise inline the interface
into `RemoteBackend` and type the controller on the concrete class. (Fold into C-1's `ApiClient` refactor
if that lands first.)

### C-12 · Six near-identical destructive-action confirm dialogs

**Kind:** `kind/duplicate` · **Area:** `area/client` · **Priority:** medium · **Effort:** S

- `api_tokens_screen.dart:198-227` (`_confirm`), `location_history_screen.dart:108-132`
  (`_confirmDelete`), `tracking_profile_tab.dart:151-178` (`_confirmSignOut`),
  `checkpoints_screen.dart:53-77`, `app_updates_card.dart:64-84`, `debug_log_screen.dart:72-88`.
- All share the `AlertDialog` + `TextButton('Cancel')` + error-filled `FilledButton` with
  `minimumSize: Size(0, 40)` shape, re-derived from `Theme.of(context).colorScheme` each time.
- Two already disagree: `debug_log_screen.dart:82` uses a plain `TextButton` for a destructive action.

**Fix:** one `confirmAction(context, {title, message, actionLabel, destructive})` in `lib/src/core/` and
six call-site replacements.

### C-13 · Chip, pill and message-state widgets duplicated across features

**Kind:** `kind/duplicate` · **Area:** `area/client` · **Priority:** medium · **Effort:** S

- `_Message` byte-identical: `travel/travel_tab.dart:494-522` and
  `tracking/widgets/location_history_screen.dart:951-979`.
- `_StatChip` byte-identical: `travel_tab.dart:467-492` and `location_history_screen.dart:924-949`.
- Five more copies of "tinted rounded container + small icon + label":
  `tracking_users_drawer.dart:936-965` (`_StatusChip`), `api_tokens_audit_screen.dart:294-320` (`_Badge`),
  `tracking_status_card.dart:210-238` (`_LiveBadge`), plus `map_variant_card.dart:61-127`.
- `_VariantPill` is a copy of `ThemePill`: `map_variant_card.dart:61-127` vs
  `widgets/appearance_card.dart:52-126` (same `StadiumBorder` primary/outlineVariant 1.5/1, same
  `minHeight: 44`, same trailing `check_rounded` at 17 px); their card wrappers match too
  (`map_variant_card.dart:26-56` vs `appearance_card.dart:19-47`).
- `formatUpdatedAgo` (`core/formatters.dart:22-30`, in use at `tracking_users_drawer.dart:638`,
  `api_tokens_screen.dart:590`, `api_tokens_audit_screen.dart:217`) is re-implemented as a local `_ago`
  three times: `app_updates_card.dart:212-218`, `tracking_status_card.dart:191-198` (byte-identical
  apart from the name) and `debug_log_screen.dart:231-238` (different units). Verified.

**Fix:** one `AppChip({icon, label, background, foreground})`, one `MessageState({icon, text, action})`,
one `SelectPill` + `SettingCard` in `lib/src/core/widgets.dart`; delete the local `_ago`s and call
`formatUpdatedAgo` (add a compact variant if the debug screen wants it).

### C-14 · `LocationSession` and `LeaderboardEntry` duplicate the same trip aggregate

**Kind:** `kind/duplicate` · **Area:** `area/client` · **Priority:** medium · **Effort:** M

- `data/models/location_session.dart:6-9` vs `data/models/leaderboard_entry.dart:8-11` — identical
  `durationSeconds`, `distanceMeters`, `avgSpeed`, `topSpeed`.
- `location_session.dart:22-28` vs `leaderboard_entry.dart:27-31` — three identical getters
  (`duration`, `avgSpeedKmh`, `topSpeedKmh`) differing only in where `* 3.6` sits.
- `location_session.dart:24` — `distanceKm` has no reader in any package; callers use
  `formatDistance(distanceMeters)`.
- Unit conversion applied twice in one screen: `tracking_users_drawer.dart:1426` mixes
  `session.avgSpeedKmh * session.durationSeconds`; the m/s→km/h factor is also open-coded at
  `speed_color.dart:21`, `session_replay_screen.dart:323`, `tracking_map_tab.dart:858`.

**Fix:** one `TripTotals` value type (distance, seconds, avg/top m/s + conversions) embedded by both,
plus one shared `msToKmh`. Coordinate with A-6.

### C-15 · Marker-bitmap caching plumbing is copied between the map and replay

**Kind:** `kind/duplicate` · **Area:** `area/client` · **Priority:** medium · **Effort:** M

- `tracking_map_tab.dart:1083-1106` vs `session_replay_screen.dart:597-619` — `_imageFor(key, build)`
  identical apart from the post-`then` call (`_publishScene` vs `_syncScene`); both re-declare `_icons`,
  `_images`, `_pendingImages`, `_iconEpoch` (`:104-116` / `:229-235`) and a matching
  `_handleIconsChanged` that clears and bumps the epoch (`:188-196` / `:406-412`).
- `marker_icons.dart:901-906` duplicates `user_avatar.dart:46-51` (`_greyscale` matrix verbatim);
  `marker_icons.dart:665-671` duplicates `user_avatar.dart:31-37` (the same FNV-1a loop).
- `marker_icons.dart:876-885` vs `tracking_users_drawer.dart:928-934` — two `_batteryIcon` functions with
  **different thresholds** (90/70/55/40/25/10 vs 90/60/40/20), so the same person shows a different
  battery glyph in the marker than in the list.

**Impact:** the subtle epoch/pending logic that guards against blink-out and stale avatars exists twice,
so each bug must be fixed twice — and the battery glyph already disagrees.

**Fix:** move the cache into `MarkerIconFactory` (it owns the bitmaps) as
`future imageFor(key, build)` + an `onInvalidated` callback; hoist `greyscale`, the FNV hash and one
battery-icon table into `core/`.

### C-16 · Per-frame marker rebuild is quadratic and re-scans the list once per layer

**Kind:** `kind/perf` · **Area:** `area/client` · **Priority:** medium · **Effort:** M

- `tracking_map_tab.dart:447-460` — `_handleMotionTick` publishes the scene ~20×/s; `:744-799` and
  `:814-1015` rebuild the full marker list, clusters, badge strings and hit areas each time.
- `features/tracking/map_geometry.dart:95-124` — clustering is O(n²) and calls `groups[i].center` inside
  the inner loop; `MarkerGroup.center` (`:77`) → `averagePosition` (`:50-60`) walks the whole group on
  every comparison, then again at `:111`.
- `tracking_map_tab.dart:864-871` — a signature string is concatenated for every group every frame.
- `mapbox_map.dart:668-674` + `:727-736` — `_syncOnce` iterates all `scene.markers` once per layer
  (8 layers) to build each `desired` map, and `_syncPointLayer` re-filters `_annotations.keys` per layer.

**Impact:** cost grows as n²·layers at 20 fps, so a busy map with a couple of dozen peers spends the frame
budget on centroid recomputation and list filtering instead of annotation updates.

**Fix:** cache each group's centroid incrementally (update on insert), bucket markers by layer once per
publish, and reuse the previous signature when a group's members are unchanged.

### C-17 · People sheet: `setState` plus a full-subtree `Opacity` on every drag frame

**Kind:** `kind/perf` · **Area:** `area/client` · **Priority:** medium · **Effort:** M

- `tracking_users_drawer.dart:126-132` — `_handleSheetChanged` calls `setState` on every controller tick,
  i.e. each pointer move while dragging.
- `:306-309,352-354` — `contentOpacity`, computed from that state, wraps the whole `Expanded` content
  (list *and* detail pane) in `Opacity`, forcing a `saveLayer` and a repaint of every visible `_UserRow`
  per frame.
- `:710-738` — `_Ticking` runs its own `Timer.periodic(1 s)` **per instance**, instantiated once per row
  (`:795`) plus twice in the detail pane (`:1150`, `:1262`): N independent 1 Hz `setState` timers scale
  with list length.
- `:95-98` and `:290-294` — two `addPostFrameCallback` re-entrant `_handleSheetChanged` reports from
  layout.

**Fix:** drive the fade from the sheet controller itself (`FadeTransition`, or an `AnimatedBuilder`
behind a `RepaintBoundary`, no `setState`), and replace `_Ticking` with one shared second-tick
`ValueListenable` inherited by the sheet.

### C-18 · `AppTokens` is a `ThemeExtension` nothing reads through the theme

**Kind:** `kind/redundant` · **Area:** `area/client` · **Priority:** medium · **Effort:** S

- `core/tokens.dart:66-86` — a class whose three members are compile-time constants; `copyWith` (`:82`)
  and `lerp` (`:85`) are no-ops returning `const AppTokens()` / `this`.
- `:78-79` — `AppTokens.of(context)` has zero call sites anywhere.
- `:73` `cardRadius` and `:76` `largeSurfaceRadius` have zero readers; callers use `AppShape.md` /
  `AppShape.xl` directly (`core/theme.dart:218,261,324`).
- `theme.dart:231` registers it in `extensions:`; `theme.dart:264` then reads
  `const AppTokens().navigationBarHeight`, bypassing the extension it was registered for.
- `test/theme_test.dart:142` — the only test asserts `extension<AppTokens>() != null`, locking in the
  wrapper without exercising behaviour.

**Fix:** delete `AppTokens` and use `80`/`AppShape` at the two call sites — or make it real (non-constant
fields, `theme.dart:264` via `AppTokens.of`).

### C-19 · Theme picker previews restate colours that already live in the palettes

**Kind:** `kind/duplicate` · **Area:** `area/client` · **Priority:** medium · **Effort:** S

- `core/theme.dart:111-115,123-127,135-139,147-151` — the four Catppuccin previews hard-code hexes that
  already exist as `base`/`surface0`/`mauve`/`text` at `:450-536`.
- `:87-93` and `:99-105` — the `oled` and `oledAdaptive` previews are identical to each other and repeat
  `0xFF0D1312`/`0xFFDDE4E1`/`0xFF82D5C8` from `oledSurfaces` (`:378-396`).
- `_CatppuccinPalette` fields `overlay0` (`:414`), `overlay1` (`:415`), `subtext1` (`:418`) are declared,
  passed at four sites each (`:458-462`, `:481-485`, `:504-508`, `:527-532`) and never read.

**Impact:** ~28 redundant lines where a palette edit and its swatch can disagree — which is how a
light-theme regression hides (the swatch looks right, the app is not). See A-8 for the cross-package copy.

**Fix:** derive `AppThemePreview` from `schemeFor(id, brightness)`
(`surface`/`surfaceContainer`/`primary`/`onSurface`) and delete the literal blocks and the three unused
palette fields.

### C-20 · Small dead symbols in `core/` and `data/`, including a duplicated Mercator constant

**Kind:** `kind/dead-code` · **Area:** `area/client` · **Priority:** low · **Effort:** S

Each verified: the sole hit is the definition.

- `data/models/user_model.dart:58-59` — `hasAnyStatus`; the three flags it ORs are read individually.
- `core/constants.dart:60` — `AppConstants.maxMercatorLatitude` unused, while
  `features/tracking/map_geometry.dart:7` keeps a private `_maxMercatorLatitude` with the same
  `85.05112878` — a duplicated constant with zero readers, inviting a future edit to one copy.
- `core/tokens.dart:23,24` — `AppShape.xsRadius` / `smRadius` (only `fullRadius`/`xlRadius` are used).
- `data/network/mapbox_token_gate.dart:41,50,107` — the `onTokenChanged` parameter is never passed by
  any of the three production call sites (`tracking_map_tab.dart:600`,
  `session_replay_screen.dart:659`, `checkpoint_editor_screen.dart:235`).
- `data/network/mapbox_token_service.dart:119-120` — a `toString()` override returning the class name,
  i.e. the default behaviour.
- `core/speed_color.dart:12` — `_speedColorStops` is a pure alias for `AppPalette.speedStops`.
- `data/network/device_service.dart:16` — `DeviceCredentials.userId` is written to prefs (`:95`) and read
  back only for a null check (`:85`); the only real reader is `test/device_service_test.dart:38,96`.

**Fix:** delete the dead members, and have `map_geometry.dart` import
`AppConstants.maxMercatorLatitude` instead of keeping a private twin.

### C-21 · `MapWidget.cameraOptions` is deprecated and the ignore hides the upgrade risk

**Kind:** `kind/dead-code` · **Area:** `area/client` · **Priority:** low · **Effort:** S

- `features/tracking/widgets/mapbox_map.dart:251-255` — `// ignore: deprecated_member_use` over
  `cameraOptions:` in the once-built `_surface`. This is the only deprecation suppression in the
  codebase.
- `mapbox_maps_flutter-2.31.1/lib/src/map_widget.dart:48-50,89-91` —
  `@Deprecated('Use [viewport] …')`, "will be removed in future major version".
- A replacement exists and is unadopted: `MapWidget.viewport` (`map_widget.dart:76,186`,
  `ViewportState?`) with `CameraViewportState { center, zoom, padding, bearing, pitch }`.
- `mapbox_map.dart:248-249` records a real globe-flash regression observed with the viewport system,
  which is presumably why it was not adopted.

**Fix:** try `viewport: CameraViewportState(center:, zoom:)` and keep `cameraOptions` only if the flash
persists; either way narrow the ignore to the exact argument line and record the trade-off in the issue.

## D. Native tracking engines (Kotlin + Swift)

### D-1 · Split the 1714-line iOS engine into the Kotlin module layout and share its test vectors

**Kind:** `kind/duplicate` · **Area:** `area/native` · **Priority:** high · **Effort:** L

- `ios/Runner/TrackingEngine.swift` is one file containing
  `Fix`/`GeoMath`/`Tuning`/`PathSampler`/`StopDetector`/`TrackingStore`/`EngineState`/`Uploader`/
  `TrackingEngine`/`TrackingChannel` — a 1:1 copy of
  `android/.../tracking/{Fix,Tuning,PathSampler,StopDetector,TrackingStore,EngineState,Uploader,TrackingEngine,TrackingChannel}.kt`.
- `ios/RunnerTests/RunnerTests.swift:7` is the empty Xcode template (`testExample`), while
  `android/.../test/.../{PathSamplerTest,StopDetectorTest,DriveSimulationTest}.kt` guard the Kotlin
  copies. Nothing tests that the Swift `PathSampler` still matches `DriveSimulationTest`, and CI runs
  neither (A-2).
- The constant table below shows six behavioural mismatches plus the two functional gaps in D-2.

**Impact:** sampler, stop-detection and upload semantics live in two languages with no shared vector, so
the only protection against drift is review — and it has already drifted.

**Fix:** split the Swift file per Kotlin module, then export the Kotlin test vectors (drive simulation →
expected stored points) as JSON under `docs/` or `test/` and add a Swift `XCTest` that replays them.

### D-2 · iOS is missing the STILL fast-stop and the jitter filter

**Kind:** `kind/duplicate` `kind/perf` · **Area:** `area/native` · **Priority:** high · **Effort:** M

Verified directly:

- `TrackingEngine.kt:1142-1145` — `stopTimeout()` returns `Tuning.STOP_TIMEOUT_STILL_MS` (2 min,
  `Tuning.kt:50`) when the device reports STILL, else `STOP_TIMEOUT_MS`;
  `TrackingEngine.swift:1137` always uses `Tuning.stopTimeout` (5 min, `:113`). No STILL branch exists
  in Swift.
- `TrackingEngine.kt:386-392` — `wasJitter()` (defined `:1000-1001`, threshold
  `Tuning.MIN_TRIP_EXTENT_M` = 150 m at `Tuning.kt:46`) discards a trip that never left the geofence,
  via `store.deleteTripFrom` (`TrackingStore.kt:123`). Grepping `TrackingEngine.swift` for
  jitter/extent logic finds nothing: no counterpart.

**Impact:** on iOS a trip keeps GPS for a full 5 minutes after the car is detected parked, and a
150 m-radius wander around the driveway uploads as a real trip — the exact "parked drift recorded as
movement" failure `docs/location-tracking.md:23` says the redesign fixed. Battery and history quality
both regress on iOS only.

**Fix:** add a stationary-confidence fast stop (speed-based, or `CLVisit`-based) and port
`MIN_TRIP_EXTENT_M` + `deleteTripFrom` to Swift.

### D-3 · All iOS SQLite, JSON and file work runs on the main thread

**Kind:** `kind/perf` · **Area:** `area/native` · **Priority:** high · **Effort:** M

- `TrackingEngine.swift:20` — the file's own comment: "Everything runs on the main thread, where
  CLLocationManager delivers."
- `:1380` `store.insert` per stored fix; `:683` `store.pending(limit: 500)`; `:699` `JSONSerialization`;
  `:711` `deleteUpTo`; `:1405`, `:1410`, `:1423` `pendingCount()` — all on the main queue.
- Kotlin does the same work off-main on `lt-engine`/`lt-upload` (`TrackingEngine.kt:68,74,785`).

**Impact:** a 500-point batch builds a 500-element dictionary array, encodes it and runs two `SELECT`s
while the Mapbox platform view is animating — the jank class `CLAUDE.md` warns about for this exact
surface — and it delays fix-delivery callbacks.

**Fix:** keep engine state on main, move `TrackingStore` (already opened with
`SQLITE_OPEN_FULLMUTEX`, `:373`) and `Uploader` body building onto a serial `DispatchQueue`, hopping
back to main for results.

### D-4 · A full `COUNT(*)` runs once per GPS fix on both platforms

**Kind:** `kind/perf` · **Area:** `area/native` · **Priority:** medium · **Effort:** S

Verified directly:

- `TrackingEngine.kt:770` and `:775` inside `maybeFlush()`, itself called per accepted fix (`:1118`);
  `TrackingEngine.swift:1405` and `:1410` from `tripFix` (`:1147`).
- The table is capped at 100 000 rows (`Tuning.kt:88`), so one long trip issues thousands of full-table
  counts.
- `pendingSince` already says "there is work"; the count only decides the 200-point
  `UPLOAD_MAX_PENDING` threshold.

**Impact:** a disk scan every second of every trip, on the battery-critical path, for a value the engine
could hold in memory.

**Fix:** keep an in-memory inserted/acked counter seeded from `store.pendingCount()` at startup only, or
bound the query (`SELECT COUNT(*) FROM (SELECT 1 FROM points LIMIT 201)`).

### D-5 · Parked-but-visible keeps GPS at 1 Hz / highest accuracy indefinitely

**Kind:** `kind/perf` · **Area:** `area/native` · **Priority:** medium · **Effort:** S

- `TrackingEngine.kt:578-582` — `PRIORITY_HIGH_ACCURACY` at 1 000 ms, started from
  `setAppVisible`/`startForegroundSession` (`:212-224`) and stopped only when the app hides (`:589`).
- `TrackingEngine.swift:1092` — `session != nil || appVisible` with `kCLLocationAccuracyBest` and
  `distanceFilter = kCLDistanceFilterNone` (`:1107-1108`).
- The stated job of that state is a 60 m displacement check (`Tuning.kt:82-83`) plus one ping fix.
- `docs/location-tracking.md:10` promises "GPS only while actually moving".

**Impact:** reading the app for ten minutes at home streams continuous full-power GPS on both platforms.

**Fix:** after `foregroundPing` completes, downgrade the visible/stationary request to ~10 s
balanced-power (Kotlin) / `kCLLocationAccuracyHundredMeters` with a 25 m filter (Swift); restore the fast
profile on `enterMoving`, live mode, or an explicit user refresh.

### D-6 · iOS re-enables and reads battery monitoring on every point and every profile tick

**Kind:** `kind/perf` `kind/duplicate` · **Area:** `area/native` · **Priority:** medium · **Effort:** S

- `TrackingEngine.swift:757` — `device.isBatteryMonitoringEnabled = true` inside `Battery.read()`, called
  per stored point (`:1379`), per live upload (`:690`), and from `lowPower()` (`:1490`) which
  `applyGpsProfile()` runs on every 20 s tick (`:1106,1369`) and every `status()` (`:1591`).
- `status()` also recomputes `trackingIssues()` (`:1599`) after reading
  `authorizationStatus`/`accuracyAuthorization` twice (`:1576-1584`), duplicating `:1555-1560`.
- Kotlin caches the reading for 60 s (`Uploader.kt:94-102`) — see the table below.

**Fix:** set `isBatteryMonitoringEnabled` once in `bootstrap`, cache `(level, charging)` for 60 s like
Kotlin, and let `status()` reuse one authorization/issues computation.

### D-7 · `notificationsEnabled` is plumbed everywhere and used nowhere — and the documented install notification can't appear

**Kind:** `kind/dead-code` · **Area:** `area/native` · **Priority:** medium · **Effort:** S

- `AndroidManifest.xml:16` declares `POST_NOTIFICATIONS`; nothing requests it
  (`lib/src/features/location/tracking_permissions.dart:14-16` says that is deliberate, and
  `requestNotifications()` at `:101` has no callers).
- `TrackingEngine.kt:894` publishes the value, `TrackingEngine.swift:1598` hard-codes `false`,
  `tracking_engine.dart:71,102,121` parses it — and no reader exists in `lib/`, `src/web` or
  `src/server`.
- `AppUpdater.kt:430-435` logs and gives up when notifications are off, so the
  "Update ready — tap to install" fallback documented at `docs/app-updates.md:36` — the path used when
  silent install is not permitted — never reaches the user on Android 13+.

**Fix:** decide the product answer: either request notification permission on the path that needs it
(`STATUS_PENDING_USER_ACTION` → `notifyUpdateReady`), or delete `notificationsEnabled` from both engines
and the Dart model and correct `docs/app-updates.md`.

### D-8 · iOS engine state can be lost on exactly the kill the design expects

**Kind:** `kind/duplicate` · **Area:** `area/native` · **Priority:** medium · **Effort:** S

- `EngineState.kt:9-13` documents "Mode and anchor changes are committed synchronously", with
  `commit()` at `:44` (mode) and `:49` (anchor).
- The Swift equivalents (`TrackingEngine.swift:558`, `:613-619`) only use `UserDefaults.set`; grep finds
  no `synchronize()` anywhere in `Runner/`.
- iOS terminates backgrounded processes routinely right after a state change (`armStationary` on
  relaunch, `:876`).

**Impact:** a lost `mode`/`anchor` write means the next wake-up re-arms the geofence at the old parking
spot, or believes a parked phone is still moving.

**Fix:** `UserDefaults.standard.synchronize()` after the `mode`/`anchor` writes (once per transition), or
persist those two keys in the SQLite file that is already flushed per insert.

### D-9 · Native cleanup: unreachable branches, template leftovers, per-point formatter allocation

**Kind:** `kind/dead-code` `kind/redundant` · **Area:** `area/native` · **Priority:** low · **Effort:** S

- `Uploader.kt:158-161` builds a new `SimpleDateFormat` (plus a UTC `TimeZone` lookup) **inside** the
  per-point loop (`:61-63`, `:175`) — 500 formatters per batch — while Swift caches one static formatter
  (`TrackingEngine.swift:654-658`).
- `TrackingEngine.kt:550` and `TrackingEngine.swift:1231` re-test
  `accuracy <= PING_MAX_ACCURACY_M` inside `moved`, twelve lines after the identical guard already
  returned (`:537`, `:1218`).
- `TrackingEngine.swift:1556-1560` and `:1578-1584` keep `#available(iOS 14)` `else` branches calling the
  deprecated `CLLocationManager.authorizationStatus()` although `project.pbxproj:367` sets the deployment
  target to 14.0; `locationManager(_:didChangeAuthorization:)` (`:1305`) is the deprecated form of
  `locationManagerDidChangeAuthorization(_:)`.
- Template leftovers: `android/app/build.gradle.kts:29` (`// TODO: Specify your own unique Application
  ID`), `ios/Runner/Info.plist:71` (`NSLocationAlwaysUsageDescription`, unused since iOS 11),
  `RunnerTests.swift:7-10` (empty `testExample`).
- `Workers.kt:24` logs `outcome.javaClass.simpleName` where the engine already has a `describe()` mapper
  that explains the HTTP reason (`TrackingEngine.kt:841`).

**Fix:** hoist one formatter per `uploadAll()` call (single-threaded by `uploadExecutor`), drop the
redundant accuracy term and the unreachable `else` branches, implement the modern authorization
delegate, delete the template strings, and reuse `describe` in the worker log.

### D-10 · Kotlin vs Swift tunable constants — full cross-check

Reference table for D-1/D-2/D-6/D-8. **K** = `android/.../tracking/Tuning.kt`, **S** =
`ios/Runner/TrackingEngine.swift`, **PS** = `PathSampler.kt`/Swift `PathSampler`, **SD** =
`StopDetector.kt`/Swift `StopDetector`, **U** = `Uploader.kt`.

| Constant | Kotlin | Swift | Status |
|---|---|---|---|
| geofence radius / max | 150 / 500 m (K:21,22) | 150 / 500 (S:104,105) | ok |
| stationary fallback fix | 15 min, min-interval 2 min (K:24,25) | significant-change, no interval (S:1105-1108) | differs by platform design |
| heartbeat | 25 min (K:27) | 25 min (S:106) | ok |
| background sweep | 30 min (K:28) | 30 min (S:107) | ok |
| GPS cadence / batching | 2 s + 30 s, live 1 s, saver 5 s + 120 s (K:31-33) | no interval API used (S:1105-1108) | **MISMATCH** |
| max record accuracy / saver | 40 / 60 m (K:36,37) | 40 / 60 (S:109,110) | ok |
| max stop accuracy | 100 m (K:38) | 100 (S:111) | ok |
| max plausible speed | 90 m/s (K:40) | 90 (S:112) | ok |
| min trip extent (jitter) | 150 m (K:46, used `TrackingEngine.kt:386-392`) | absent | **MISMATCH — D-2** |
| stop timeout | 5 min (K:48) | 5 min (S:113) | ok |
| stop timeout when STILL | 2 min (K:50, `TrackingEngine.kt:1142-1146`) | absent | **MISMATCH — D-2** |
| no-fix timeout | 5 min (K:52) | 5 min (S:114) | ok |
| session tick | 20 s (K:53) | 20 s (S:115) | ok |
| alarm backstop for tick | 6 min (K:55) | absent (Timer only) | **MISMATCH — D-1** |
| resume window | 10 min (K:57) | 10 min (S:116) | ok |
| upload batch / age / pending | 500 / 5 min / 200 (K:60-64) | 500 / 5 min / 200 (S:118-120) | ok |
| upload backoff | 30 s → 10 min (K:65,66) | 30 → 600 s (S:121,122) | ok |
| live min interval / distance / keepalive | 2.5 s / 8 m / 30 s (K:69-71) | 2.5 / 8 / 30 (S:124-126) | ok |
| ping min interval / good acc / timeout / max acc | 10 min / 20 m / 15 s / 100 m (K:73-78) | 10 / 20 / 15 / 100 (S:127-131) | ok |
| foreground move threshold / accuracy | 60 / 30 m (K:82,83) | 60 / 30 (S:133,134) | ok |
| low battery | 15 % (K:85) | 15 (S:135) | ok |
| max stored points / log entries | 100 000 / 500 (K:88,89) | 100 000 / 500 (S:137,138) | ok |
| sampler ε / min / 8 s / 30-200 / Δv 3 / 30 % | PS:29-35 | S:143-151 | ok |
| sampler SAVER 12 / 15 / 300 | PS:41 | S:153 | ok |
| departure gap / speed / window | 3000 m / 1.5 / 400 (PS:200-204) | 161-165 | ok |
| stop radius / max / moving | 40 / 100 m / 2.5 m/s (SD:14,15,88) | 290-294 | ok |
| HTTP connect / read timeout | 15 s / 30 s (U:133,134) | 30 s request timeout, **no connect timeout** (S:649) | **MISMATCH — D-1** |
| battery read cache | 60 s (U:94-102) | none; re-enabled every call (S:757) | **MISMATCH — D-6** |
| state durability on kill | `commit()` for mode/anchor (`EngineState.kt:44,49`) | `UserDefaults`, never flushed (S:556-619) | **MISMATCH — D-8** |

Nine mismatches. All the numeric tuning values that *do* exist agree to the digit, which is itself
evidence the ports were careful — the failures are missing features on the iOS side, not drifted numbers.

## E. Web app — logic layer (`src/web/src/{api,stores,lib,composables}`)

### E-1 · The peers store clones its whole Map on every stream message

**Kind:** `kind/perf` · **Area:** `area/web` · **Priority:** high · **Effort:** M

Verified directly:

- `src/web/src/stores/peers.ts:35` — `const next = new Map(peers.value)` per WebSocket message; `:36`
  assigns the clone whenever `applyMessage` reports a change.
- `src/web/src/lib/peers.ts:118` — `peers.set(id, peer); return true` returns true for **any** valid
  `user_id`, even a byte-identical roster or `last_seen` refresh. There is no no-op path.
- `stores/peers.ts:22` — the `list` computed re-spreads a new array per message, so every dependent
  recomputes (`views/MapView.vue:99,107`).
- `components/PeersMap.vue:401` — the watch fires `sync()` on that new array **and** on the 5 s `now`
  prop; `:140` then calls `view.update(…)` which re-renders **every** marker's Vue tree
  (`lib/vueMarker.ts:81`), plus `setLabel` DOM writes (`:141`).
- `PeersMap.vue:153,218-226` — `regroup()` re-projects all points and re-clusters from scratch even when
  only `now` ticked; `lib/clusters.ts:77-94` uses `findIndex` over centroids per point plus `mean()`
  re-averaging all members on each insert → O(n²) with fresh arrays.

**Impact:** with several phones live (fixes every 1–3 s), each single-peer update cascades into a full
Map clone, a full array rebuild, a Vue re-render of every marker and a full re-cluster. Cost scales with
fleet size × message rate rather than with what changed, and the 5 s staleness tick pays it for nothing.
The client twin is C-7.

**Fix:** have `applyUpdate` diff against `existing` and report whether any field actually changed; mutate
the existing Map and bump a per-peer revision (or a changed-id set) instead of replacing it; split the
`PeersMap` watch so `now` re-labels only stale markers without `regroup()`.

### E-2 · Extract one dialog shell and one loading/error/empty trio

**Kind:** `kind/duplicate` · **Area:** `area/web` · **Priority:** high · **Effort:** M

- Byte-identical full-screen sheet: `components/account/ApiTokensDialog.vue:240-249` and
  `ApiTokenRequestsDialog.vue:72-81` (same scrim class, same
  `bg-surface-container scroll-panel shadow-level-3 … sm:max-h-[90vh] sm:max-w-lg` section).
- Identical centred card shell: `components/ui/ConfirmDialog.vue:23-34` and
  `AppearanceDialog.vue:29-39`.
- "spinner, centred" six times: `views/MapView.vue:555`, `components/places/PlacesPanel.vue:269`,
  `components/history/TripHistory.vue:110`, `components/travel/TravelLeaderboard.vue:158`,
  `ApiTokensDialog.vue:394`, `ApiTokenRequestsDialog.vue:119`.
- "cloudOff + message + Retry" three times: `ApiTokensDialog.vue:395-407`, `:580-592`,
  `ApiTokenRequestsDialog.vue:121-132`.
- "No X yet" panel three times: `ApiTokensDialog.vue:408-413`, `:593-598`,
  `ApiTokenRequestsDialog.vue:133-139`.
- Icon-over-text empty/error state six times: `TripHistory.vue:81-90,113-116,117-120,134-137`,
  `TravelLeaderboard.vue:148-157,160-166`.
- `function message(error)` verbatim twice: `ApiTokensDialog.vue:67-69`,
  `ApiTokenRequestsDialog.vue:19-21`.

**Impact:** ~170 lines that must each be re-audited against the token rule (F-1) on every change, and they
already drifted — the two `Retry` blocks differ in z-index, padding and aria attributes.

**Fix:** `ui/Dialog.vue` (scrim + panel + `useModal` + optional `z` and header slot) and
`ui/StateBlock.vue` with `kind="loading|error|empty"` + a `retry` prop; move `message()` to a small
`lib/errors.ts`.

### E-3 · Merge the two token-row markups inside `ApiTokensDialog`

**Kind:** `kind/duplicate` · **Area:** `area/web` · **Priority:** high · **Effort:** M

- `components/account/ApiTokensDialog.vue:421-471` (the account's own tokens) vs `:618-656` (the
  everyone/audit list): same name + scope badge (`:426-432` vs `:622-630`, an identical ternary), same
  hint line, same `usage(token)`, same `allowedIps.join(', ')` with `:title`, same Activity button. The
  only difference is the Edit/rotate/delete controls.
- The second list also copies the loading/error/empty block and the tab strip (see E-2).

**Impact:** adding one field to a token row (say last-used IP) is two edits, and the audit list is already
missing the `allowedIps` styling consistency of the first.

**Fix:** `components/account/ApiTokenRow.vue` taking `token`, `owner?`, `expanded?` with an `#actions`
slot; the "mine" list passes Edit/Rotate/Delete, the audit list passes nothing.

### E-4 · Error handling and numeric coercion are copied seven times across the API layer

**Kind:** `kind/duplicate` · **Area:** `area/web` · **Priority:** medium · **Effort:** S

- Canonical: `api/tracker.ts:26-32` (`trackerJson`) and `:58-62` (`isAccessLost`).
- Bypassed by `api/history.ts:78,101`, `api/leaderboard.ts:45`, `api/apiTokens.ts:121-126`,
  `stores/sharing.ts:10-13`, `stores/checkpoints.ts:95` — five modules hand-rolling
  `` `Tracker error (${status})` `` and the `json().catch(() => null) as {error?: unknown}` dance.
- Verbatim `num()` in `api/history.ts:23` and `api/leaderboard.ts:16`; near-verbatim `time()` in
  `api/history.ts:28`, `api/apiTokens.ts:54`, `lib/peers.ts:51`.
- `not_sharing` matched twice: `api/history.ts:98` and `lib/peers.ts:92`.
- Divergent behaviour is already visible: only `apiTokens` surfaces the server's message; the rest
  swallow it.

**Fix:** export one `ensureOk(response)` + `serverErrorText(response)` from `api/tracker.ts` and one
`lib/coerce.ts` with `num`/`time`; delete the local copies.

### E-5 · Local-date arithmetic sits in a store and is duplicated in `lib/periods`

**Kind:** `kind/duplicate` · **Area:** `area/web` · **Priority:** medium · **Effort:** S

- `stores/history.ts:9,13,17,21` — `startOfDay`/`addDays`/`startOfMonth`/`addMonths`.
- `lib/periods.ts:15-17` (`day()` — identical), `:24-25` and `:35` re-type the same month edges inline;
  further inline copies at `lib/events.ts:89` and `components/history/CalendarCard.vue:36`.
- Consumers import the math **from the store**: `stores/leaderboard.ts:14`,
  `components/people/PersonDetail.vue:18`, `components/travel/TravelLeaderboard.vue:35`,
  `components/history/TripHistory.vue:76`.

**Impact:** a DST or month-end fix has to be made in six places, and pure date logic is only reachable by
importing a Pinia store.

**Fix:** move the helpers to `lib/dates.ts`, have `periods.ts` consume it, and update the ~five importers.

### E-6 · Dead exports, dead icons and dead store members in the logic layer

**Kind:** `kind/dead-code` · **Area:** `area/web` · **Priority:** low · **Effort:** S

Icons verified by grep (zero references outside `lib/icons.ts`):

- `lib/icons.ts:23` (`dateRange`), `:38` (`landscape`), `:63` (`shield`), `:72` (`trophy`), `:74`
  (`visibility`) — each imported `?raw` and mapped (`:99,:114,:139,:147,:149`) with no user;
  `Icon.vue:9` only indexes by the literal `IconName` union. The battery glyphs **are** used
  (`:111-120`) and stay.
- `stores/history.ts:75` `active` computed (also returned at `:210`) — no consumer in `views/`,
  `components/` or `src/web/src/test/`.
- `stores/sharing.ts:20,54` — `hiddenFrom` exported but only `isSharingWith` is read
  (`PersonDetail.vue:106`).
- Exported yet used only inside their own file: `lib/avatars.ts:25` `relativeLuminance`,
  `lib/motionTokens.ts:7` `prefersReducedMotion`, `lib/geocoder.ts:9` `normalizeLocation`,
  `lib/streets.ts:116` `streetNames`, `lib/peers.ts:28` `STALE_AFTER_MS`, `lib/replay.ts:19,20,38,92`,
  `lib/clusters.ts:34,41`, `stores/history.ts:7` `MONTHS_BACK`, `api/oidc.ts:23,27`,
  `api/apiTokens.ts:29`, `api/stream.ts:5`, `theme/themes.ts:6,8`, `lib/presence.ts:5`,
  `lib/tracking-issues.ts:17,22`, `lib/jwt.ts:1`.
- `api/stream.ts:10,86-91` — the `onFatal` option is set only by `src/test/stream.test.ts:200`; the sole
  production caller (`stores/peers.ts:44-50`) sets `isFatal` only, and `isFatal` already stops the
  client. `lib/tracking-issues.ts:30,35` — `KNOWN.has(issue)` iterates `TRACKING_ISSUES`, so the second
  predicate can never be false.

**Impact:** `?raw` imports are baked into the shipped JS chunk, so dead icons are real bundle weight plus
a misleading union; the rest read as extension points nobody uses.

**Fix:** delete the five icon pairs, `active`, and the `onFatal`/`KNOWN` dead logic; make the
file-local helpers non-exported (or export only where a test genuinely needs them).

### E-7 · `PersonDetail` re-fetches and re-aggregates what the history store already owns

**Kind:** `kind/duplicate` · **Area:** `area/web` · **Priority:** medium · **Effort:** M

- `components/people/PersonDetail.vue:53-65` calls `fetchSessions(peer.id, startOfDay(now), addDays(…),
  false)` directly with its own supersede counter (`:51`), duplicating `stores/history.ts:100-117`
  (`selectDay` + the `dayRequest` guard, same call).
- `PersonDetail.vue:70-78` sums trips, duration, top and average speed — the same per-day aggregation as
  `stores/history.ts:32-45` (`summarizeByDay`, `DaySummary` at `:25`).
- `:68` re-fetches whenever `peer.sharing` flips.

**Impact:** two owners fetch the same window and compute "one day of trips" two different ways, so the
details card and the history panel can disagree, and opening a person costs an extra request.

**Fix:** expose `todaySummary(peerId)` on the history store (or a `fetchDaySummary` in
`api/history.ts`) returning `DaySummary` plus speeds, and let the card consume it instead of owning
request state.

### E-8 · Geocode caches grow unbounded and re-serialize on every answer

**Kind:** `kind/perf` · **Area:** `area/web` · **Priority:** medium · **Effort:** S

- `lib/geocoder.ts:19` — unbounded `cache`; `:67-68` writes
  `JSON.stringify(Object.fromEntries(this.cache))` to `localStorage` **after every lookup**, so N answers
  cost O(N²) serialization and the blob never shrinks or expires.
- `lib/streets.ts:49-50,90` — a `reactive` Map keyed by `lat.toFixed(4),lng.toFixed(4)` (`:39-41`),
  appended for every distinct position a session touches, with no eviction or persistence.
- `lib/avatars.ts:74-75` — `requested` and `pictures` likewise never cleared.

**Impact:** `docs/web-app.md:96-97` promises every answer is cached; a never-pruned cache eventually
writes hundreds of KB of JSON on the main thread after each 1.1 s lookup, and the reactive street Map's
growth makes every `PlaceLabel` computed track an ever-larger collection. The client twin is C-9.

**Fix:** cap both caches with an insertion-order LRU of a few hundred entries, and write the event cache
once per `geocode()` pass rather than per entry.

### E-9 · The cross-tab `storage` listener added in store setup is never removed

**Kind:** `kind/perf` `kind/dead-code` · **Area:** `area/web` · **Priority:** low · **Effort:** S

Verified directly: `stores/session.ts:296` adds `window.addEventListener('storage', …)` inside the store
factory with no teardown counterpart anywhere in the file.

- The handler treats `event.key === null` (`:298`) as "another tab signed out", which any
  `localStorage.clear()` also fires — including cache writes from `lib/geocoder.ts` and from tests.
- Every `createPinia()` in `src/web/src/test/*` adds one more permanent listener.

**Impact:** listener count and cross-test state bleed grow with the suite; in the app a stray `clear()`
silently drops the access token during a legacy session.

**Fix:** register once per window (module-level guard) or return a disposer from `onScopeDispose`, and
match the explicit `STORAGE_KEY` instead of `key === null`.

### E-10 · `VITE_OIDC_CLIENT_ID` is read but documented nowhere

**Kind:** `kind/dead-code` · **Area:** `area/web` · **Priority:** low · **Effort:** S

See A-12 for the full env-var list; filed separately because the fix is in `src/web`.

- `config.ts:9` reads `env.VITE_OIDC_CLIENT_ID`; `env.d.ts:6` declares it; `src/web/.env.example` omits it
  (it carries the five URLs plus the Mapbox token only); `CLAUDE.md:36` and `docs/web-app.md:130` list the
  overrides without it. Every variable that *is* in `.env.example` is read, and `ci.yml:110` sets only
  the Mapbox token.

**Fix:** add `VITE_OIDC_CLIENT_ID=tracker-spa` to `.env.example` with a one-line comment and mention it in
the two env-var lists.

## F. Web app — components and views

### F-1 · Hard-coded colours on markers and route dots break the light themes

**Kind:** `kind/redundant` `kind/duplicate` · **Area:** `area/web` · **Priority:** high · **Effort:** S

Verified directly:

- `components/map/PeerMarker.vue:89-92` — `.peer-marker--stale` sets `--beam: #9e9e9e` and `--ring:
  #9e9e9e` (twice) plus `--badge-text: #fff`. `#9e9e9e` is already the token `--color-stale`
  (`style.css:78`), so the value is defined twice.
- `components/history/TripCard.vue:32,34` — `border-2 border-white` on the departure/arrival dots
  (Tailwind `#fff`).
- `components/EventsLayer.vue:131` — `.event-marker { border: 2.5px solid #fff }`.
- `components/ReplayLayer.vue:357` — `.replay-endpoint { border: 3px solid #fff }`.
- `components/BrandMark.vue:68-69` — `rgb(130 213 200 / 0.45)` and `…/0.25`, the literal teal of
  `--color-primary` (`#82d5c8`), hard-coded in a gradient and a border.

**Impact:** `style.css:242-277` defines Catppuccin Latte, a light theme — white marker rings and
`#fff` badge text read as nothing or as a blown-out pill, and the BrandMark ring stays teal on purple
themes. Each is also a second definition of a value the token system already owns, which is what
`CLAUDE.md` forbids ("use the colour tokens, never hard-coded colours or `white/…`").

**Fix:** `var(--color-stale)`, `var(--color-outline-variant)`, `var(--color-on-primary-container)`; add
one `--color-marker-ring: color-mix(in srgb, var(--color-surface) 85%, transparent)` used by TripCard,
EventsLayer and ReplayLayer; in BrandMark use
`color-mix(in srgb, var(--color-primary) 45%, transparent)`.

### F-2 · Consolidate the segmented tab controls and the repeated class strings

**Kind:** `kind/duplicate` · **Area:** `area/web` · **Priority:** medium · **Effort:** M

- Four `role="tablist"` segmented controls with the same active/inactive class pair
  (`bg-secondary-container text-on-secondary-container` /
  `text-on-surface-variant hover:bg-on-surface/…`): `views/MapView.vue:472-509`,
  `components/travel/TravelLeaderboard.vue:65-85`, `components/account/ApiTokensDialog.vue:267-301`,
  `components/ReplayLayer.vue:318-338`.
- The arrow-key tab handler is copied verbatim (`MapView.vue:151-153` ≡
  `TravelLeaderboard.vue:58-60`) while the tokens tablist has **no** `@keydown` and no tabpanel wiring —
  the odd one out for a11y.
- `text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full`
  eleven times: `PlacesPanel.vue:304`, `CalendarCard.vue:75,84`, `ApiTokensDialog.vue:259,550,558`,
  `ApiTokenRequestsDialog.vue:95,105`, `TravelLeaderboard.vue:102,111`, `ReplayLayer.vue:294`.
- `text-primary type-label-lg hover:bg-on-surface/5 rounded-full px-3 py-2` seven times (incl.
  `TripHistory.vue:85`, `TravelLeaderboard.vue:152`).
- The stat pill string three times: `TripCard.vue:68`, `TravelLeaderboard.vue:221,229`.
- The filled/secondary button string in four variants: `LoginView.vue:55`, `PlacesPanel.vue:249`,
  `ApiTokensDialog.vue:381,532`, `PersonDetail.vue:157,214`, `ReplayLayer.vue:340`; plus two different
  range-slider looks (`.m3-slider` `ReplayLayer.vue:308` vs `accent-primary` `PlacesPanel.vue:241`).
- Formatting duplicated in templates: m/s→km/h at six sites and the `x === 1 ? 'trip' : 'trips'` pair at
  `TravelLeaderboard.vue:170,201`, `TripHistory.vue:30,63`, `PersonDetail.vue:199` — no `formatSpeed` or
  `plural` exists in `lib/format.ts`.

**Impact:** ~120 lines of class soup where the only guard against a light-theme regression is reading every
string; rounding and units already differ slightly between sites.

**Fix:** `ui/IconButton.vue`, `ui/TextButton.vue`, `ui/Button.vue` (variant prop), `ui/StatPill.vue`,
`ui/SegmentedTabs.vue` (owning `moveFocus`, `aria-selected`, roving tabindex) — or a `cva` variant map in
`lib/variants.ts` if components feel too invasive. Add `formatSpeed`/`plural` to `lib/format.ts` (A-6).

### F-3 · Factor the map-layer "redraw after `style.load`" boilerplate into a composable

**Kind:** `kind/duplicate` · **Area:** `area/web` · **Priority:** medium · **Effort:** S

- Three copies of the same three-part shape — "try paint / catch `isStyleNotLoaded`", "off/on
  `style.load` with previous-map cleanup", "remove layer then remove source by id":
  `components/CheckpointsLayer.vue:43-50` + `:29-35` + `:106-116`;
  `components/places/PlaceDraftLayer.vue:74-81` + `:38-44` + `:102-113`;
  `components/ReplayLayer.vue:93-100` + `:82-91` + `:257-265`.

**Impact:** ~60 lines; the replay copy already needed extra resume logic (`paintedTrack`) bolted next to
the same shape, so a fix in one does not reach the others.

**Fix:** `composables/useMapLayers(draw)` owning the `style.load` wiring plus
`removeIds(map, layers, sources)`.

### F-4 · The staleness timer re-renders every marker while MapView re-renders every second

**Kind:** `kind/perf` · **Area:** `area/web` · **Priority:** medium · **Effort:** M

- `components/PeersMap.vue:401` watches `props.now`, fed by a 5 s `useNow()` at `views/MapView.vue:67`;
  `sync()` then calls `update(markerProps(peer))` (`:140`) — a fresh object → full `render(h(…))` per
  marker (`lib/vueMarker.ts:81`) — plus `setLabel()` (`:141`) and `setZIndex()` (`:145`) for every
  marker, although only `stale` can have changed.
- `MapView.vue:68` (`useNow(1_000)`) is read in the template (`:550`, `:566`), so the ~280-line MapView
  template re-runs every second; `:551` builds a **new** `{ lat, lng }` object each render, so
  `PersonDetail` re-renders and recomputes `distance` (`PersonDetail.vue:41-45`) per second;
  `:479-483` re-allocates the tab options array on every render.
- `components/history/CalendarCard.vue:96` keys the day cells on `:key="i"` over a list whose
  leading-blank count and month length vary, reusing day buttons across months.

**Fix:** hoist `TAB_OPTIONS` and the viewer object to module const / `computed`, key the calendar on
`cell?.date.getTime() ?? 'blank-' + i`, and in `sync()` compare the derived `markerProps` fields (or
split `stale` into its own ref) before calling `update`/`setLabel`. Shares a fix with E-1.

### F-5 · The places editor repaints the draft circle on every map-move frame

**Kind:** `kind/perf` · **Area:** `area/web` · **Priority:** medium · **Effort:** S

- `components/places/PlaceDraftLayer.vue:85-91` emits `move` on the raw map `move` event (per frame) →
  `views/MapView.vue:155-157` allocates a new `crosshair` object → `components/places/PlacesPanel.vue:78-85`
  writes `point` and `publish()` → `emit('draft')` → `MapView.vue:542` sets `placeDraft` →
  `PlaceDraftLayer.vue:114` `draw()` → `circlePolygon()` (`:33`) + `source.setData()`; the same chain also
  re-renders the MapView template because `crosshair` is read at `:336`.

**Impact:** dragging the map with the editor open runs polygon math, a GeoJSON update and a full template
re-render ~60×/s for a coordinate nobody can read mid-gesture.

**Fix:** throttle `onMove` (~100 ms) or resolve the crosshair coordinate inside `PlaceDraftLayer` on
`moveend`, and keep `crosshair` out of MapView's template.

### F-6 · Escape/close handling is re-implemented in every overlay

**Kind:** `kind/duplicate` · **Area:** `area/web` · **Priority:** medium · **Effort:** S

- `components/account/ApiTokensDialog.vue:220-234` (layered escape), `components/ui/ConfirmDialog.vue:12-17`,
  `components/ui/AppearanceDialog.vue:17-22`, `components/ReplayLayer.vue:253-266` (a `window` listener
  added at setup rather than `onMounted`), `components/ui/PopoverMenu.vue:27-34` — five
  `addEventListener('keydown', …)` blocks plus five matching removals.
- `lib/focus.ts:31-50` (`useModal`) already owns keydown wiring but only handles `Tab`.

**Impact:** five stacked global keydown listeners per dialog path, each with its own precedence hack
(`if (event.key !== 'Escape' || pending.value) return`) — which is exactly where double-close and
focus-loss bugs come from.

**Fix:** give `useModal` an `onEscape` option (it already adds/removes a document listener and knows the
modal depth) and delete the five local handlers.

### F-7 · Dead component API: unused prop, unused expose, phantom CSS class, orphan test hooks

**Kind:** `kind/dead-code` · **Area:** `area/web` · **Priority:** low · **Effort:** S

- `components/map/MapControlButton.vue:5,11` — the `active` prop is passed by none of its seven call
  sites (`MapView.vue:385,419,423,434,435,439`), so the `text-primary` branch is unreachable.
- `components/places/PlacesPanel.vue:175` — `defineExpose({ open })`: MapView mounts it (`:539-544`) with
  no `ref`, and `test/checkpoint-editing.test.ts` drives the editor through `find('[data-add]')`; nothing
  calls `vm.open`.
- `components/EventsLayer.vue:65` — `className: 'lt-popup'` matches no CSS rule anywhere in the repo
  (popup styling lives at `style.css:423-472`).
- Data hooks with no reader in any test or component: `MapView.vue:344` `data-crosshair`,
  `ApiTokensDialog.vue:321` `data-issued`, `ApiTokenRequestsDialog.vue:99` `data-refresh-requests`,
  `:190` `data-load-more`, `PlacesPanel.vue:210` `data-result`, `TripCard.vue:25` `data-trip`,
  `TravelLeaderboard.vue:207` `data-distance`, `TripHistory.vue:99` `data-delete-day`.
- `components/ApiTokensDialog.vue:57-65,116-118,163-166` — grouping of the flat `/api-tokens/all`
  response, an `ownerOf()` runtime `'userName' in token` narrowing, and an inline pluralize all live in
  the component while `lib/` owns every other pure function (so none of it is unit-tested the way
  `lib/clusters` and `lib/format` are).

**Fix:** delete the `active` branch, the `defineExpose`, `lt-popup` and the eight orphan hooks; move the
token grouping to a tested `lib/apiTokensView.ts` and give the two lists distinct types so `ownerOf`
disappears.

### F-8 · Trim unused CSS token declarations and the three competing `color-scheme` mechanisms

**Kind:** `kind/dead-code` `kind/duplicate` · **Area:** `area/web` · **Priority:** low · **Effort:** S

- Ten tokens never used by any component — `--color-tertiary`, `--color-on-tertiary`,
  `--color-tertiary-container`, `--color-on-tertiary-container`, `--color-surface-dim`,
  `--color-surface-bright`, `--color-inverse-surface`, `--color-inverse-on-surface`,
  `--color-inverse-primary`, `--color-surface-tint` — declared in the base block (`style.css:59-68`) and
  in all six `data-theme` blocks (`:113-122`, `:150-159`, …), ≈60 dead lines. The only references are
  `src/test/themes.test.ts:106-115`, which asserts they exist.
- `html[data-theme='oled']` (`:94-129`) re-declares 21 of its 33 colour tokens with the very value it
  already inherits (`--color-primary`, `--color-on-surface`, all tertiary/inverse, `--color-scrim`,
  `--color-error*`); the other themes likewise re-declare `--color-scrim`/`--color-shadow` unchanged.
- Unused type utilities: `style.css:280-301` (`type-display-lg/md/sm`, `type-headline-lg/md`) and `:549`
  (`duration-extra-long`) — zero matches in any `.vue` file.
- Three competing `color-scheme` mechanisms: `:363-365`, the per-theme lines
  (`:91,128,165,202,239,276`) and the inline `root.style.colorScheme` at `theme/themes.ts:98`, which
  always wins.

**Impact:** every new theme must repeat ~33 lines to satisfy a test that checks declarations no component
reads, and the OLED block's copy-paste hides which values it actually changes.

**Fix:** drop the unused tokens and the assertions that pin them, keep only genuinely overridden
declarations per block, and delete the `data-theme` + base `color-scheme` lines in favour of the one
mechanism that wins.

## G. Suggested grouping into PRs

Several findings are one change seen from two packages. Fixing them together avoids touching the same
code twice:

| Bundle | Findings | Why together |
|---|---|---|
| **CI green first** | A-1, A-2, A-3, A-15, A-16 | One workflow PR; no code changes, unblocks every later bundle |
| **Client network layer** | C-1, C-6, C-8, C-11, C-5 | `ApiClient` + `UserProfile.fromJson` + one `http.Client` deletes `MockBackend`, the throwaway backends and seven exception classes in one pass |
| **Client UI kit** | C-3, C-12, C-13, C-18, C-19 | Shared widgets in `core/widgets.dart` + a derived theme preview |
| **Realtime fan-out (both clients)** | C-7, E-1, F-4 | One coalescing rule: emit per frame, not per point, on both surfaces |
| **Geocoding** | C-4, C-9, E-8, A-5 | One `NominatimClient` per platform with throttle + LRU + coarse cache key |
| **iOS engine parity** | D-2, D-5, D-6, D-8, D-3 | Restore parity with Kotlin, then D-1 makes the parity testable |
| **Server read paths** | B-1, B-2, B-11, B-12 | Set-based queries + row caps + one retention job |
| **Server hot path** | B-3, B-4, B-9, B-8 | Serialize once, add one index, sweep the maps, drop `viewer_state` |
| **Schema authority** | B-10, B-4 (index), B-6 | `schema.sql` becomes the single source; `ensureBackendSchema` keeps two statements |
| **Server route hygiene** | B-5, B-7, B-13 | `preHandler` + delete the dead WS branch and the test-only checkpoint resolver |
| **Contract + docs** | A-4, A-12, A-13, A-14, E-10, B-14 | One PR that generates the docs and env lists from the route table |
| **Design tokens** | A-8, F-1, F-8, C-19 | One token source feeding CSS, Dart and the previews; deletes the hard-coded colours at the same time |
| **Dead-code sweep** | C-10, C-20, C-21, D-9, E-6, F-7 | Mechanical, low risk, good first issues |

## Appendix 1 — Checked and found clean

Recorded so these are not re-audited or re-filed.

**Flutter client** — `data/models/{api_token,tracking_issue,calendar_event,map_viewer,checkpoint}.dart`,
`data/network/oidc_service.dart`, `core/{periods,palette,theme_settings}.dart`, `main.dart`,
`firebase_options.dart` are tight: no dead symbols, no duplication.
`core/{tokens,periods,speed_color,palette,navigation}.dart`, `theme.dart` (widely used),
`features/tracking/{map_settings,map_variant}.dart`, `widgets/tracking_map_layer.dart`,
`map_contents_semantics.dart`, `selection_back_guard.dart`,
`features/calendar/calendar_events_provider.dart`, `features/checkpoints/checkpoints_provider.dart`,
`features/tracking/sharing_provider.dart`, `avatar_pictures.dart`, `local_avatar_store.dart`,
`connection/connection_monitor.dart`, `features/location/*`, `update_required_gate.dart` — no dead
exports, no unused params, and every listener, timer and subscription is cancelled.
The `MapScene` rule holds throughout `features/`: no per-frame marker or replay data is passed through
widget arguments (`session_replay_screen.dart:264,454-480` routes playback through `_scene.markChanged`;
`tracking_map_tab.dart:710-717` routes the sheet extent through a `ValueNotifier`, not `setState`).
`main_mapcheck.dart` duplicates scene-marker assembly from `tracking_map_tab`, but it is the documented
standalone spike (`CLAUDE.md:45`, `docs/mapbox.md:344`) and `MAPBOX_TOKEN_ALT` is real — not dead code.
No `console`-style debug logging, and the only deprecation suppression in the codebase is C-21.

**Server** — all 28 registered routes have live callers (checked across `src/client/lib`, `src/web/src`,
`src/client/android`, `docs/` and `README.md`): `/api/v1/{sharing,profile,fcm-token,devices,checkpoints}`,
`/api-tokens[/all|:id/rotate|:id/requests]`, `/mapbox/token`, `/leaderboard`, `/history` GET+DELETE,
`/streams/ticket`, `/app/android/latest`, `/location`, `/auth/backchannel-logout`, `/health`.
No `SELECT *` anywhere. `insertLocationBatch` (`app.ts:977-988`) is already a single multi-row
`jsonb_to_recordset` upsert. Every `WHERE user_id AND recorded_at` predicate is served by
`location_history_user_recorded_at_idx` (`schema.sql:114`). No commented-out code. The timers at
`app.ts:2359-2364`, `live-controller.ts:45,57` and `viewer-presence.ts:57` are all `unref()`'d and
cleared on their state transitions. `api_token_requests` indexes (`schema.sql:86-90`) cover both read
shapes.

**Web** — `lib/openapi.ts` paths and methods (21 paths, 27 operations) match the Fastify route
registrations exactly; the only server routes absent are `GET /health` and `POST /auth/backchannel-logout`,
both non-public (A-12 covers documenting `/health`). Documented window caps (`openapi.ts:419`: 30 days,
or 93 with `points=false`; leaderboard 366 days) match `app.ts:180` and `README.md:267-274`.
All six `THEMES` (`theme/themes.ts:28-71`) have `data-theme` blocks (`style.css:90,94,131,168,205,242`).
No `console.log`, no `debugger`, no `v-for` without a key, no `deep: true` watchers, no leaky listeners
in `.vue` files (every `addEventListener` is paired in `onBeforeUnmount`; `useMediaQuery.ts:9`,
`PopoverMenu.vue:66`). Both documented map rules hold: markers patch in place through
`VueMarker.update` (`lib/vueMarker.ts:81`) with an `attached` guard, and following uses `panBy`
(`lib/camera.ts:101`).

**Native** — the Kotlin/Swift numeric tuning values that exist on both sides agree to the digit (see the
table in D-10): batching, backoff, live/ping/foreground thresholds, sampler ε and departure rules, stop
detector radii, storage caps. Visit monitoring is **not** deprecated, so its use is not a finding.

**Repo** — no tracked `build/`, `dist/`, `node_modules/` or `.dart_tool/` (verified with `git ls-files`).
`.claude/skills/material-3` is a **symlink** to `.agents/skills/material-3`, not a stale copy.
`@types/ws` and `dotenv` in `src/server` are genuinely used. `flutter_lints` is used at
`analysis_options.yaml:16`. README, OpenAPI and route status codes agree for `your_ip`, `201` and the
API-token endpoints.

## Appendix 2 — Turning this into issues

Create the label set once (adjust names to whatever the repo already uses):

```bash
cd /home/ubuntu/git_projects/legacytracker
for l in kind/duplicate:#aaaaaa kind/dead-code:#888888 kind/redundant:#c5c5c5 \
         kind/perf:#1d76db kind/drift:#d4c5f9 ci:#0e8a16 docs:#0075ca \
         area/client:#fbca04 area/native:#b60205 area/server:#1d76db area/web:#5319e7 area/repo:#ededed \
         priority/high:#b60205 priority/medium:#fbca04 priority/low:#0e8a16 \
         effort/S:#0e8a16 effort/M:#fbca04 effort/L:#b60205; do
  gh label create "${l%%:*}" --color "$(echo "${l#*:}" | tr -d '#')" --repo Legacy-xForce/legacytracker || true
done
```

Each finding is one `### <ID> · <title>` heading followed by a `**Kind:** … **Effort:**` metadata line
and prose, so issues can be split mechanically. These snippets were run against this file and verified;
this report does **not** create issues on its own.

```bash
f=docs/code-quality-audit-2026-10-31.md
id=B-1                      # the finding's ID, e.g. A-14, C-12, D-2, F-8
start="### $id "

# title, labels, body
title=$(awk -v s="$start" 'index($0,s){split($0,p,"· "); print p[2]; exit}' "$f")
meta=$(awk  -v s="$start" 'index($0,s){f=1; next} f && /^\*\*Kind:/{print;exit}' "$f")
labels=$(printf '%s\n' "$meta" | tr '`' '\n' | grep -E '^(kind/|area/|ci$|docs$)')
labels="$labels
priority/$(printf '%s\n' "$meta" | sed -n 's/.*Priority:[^a-z]*\([a-z]*\).*/\1/p')
effort/$(printf '%s\n'  "$meta" | sed -n 's/.*Effort:[^SML]*\([SML]\).*/\1/p')"
body=$(awk -v s="$start" 'index($0,s){f=1} f && !index($0,s) && /^(### |## )/{exit} f' "$f")

echo "$title"; echo "$labels" | sed '/^$/d'   # review before publishing
```

Create it once the labels look right:

```bash
gh issue create --repo Legacy-xForce/legacytracker \
  --title "$title" --label "$(echo "$labels" | sed '/^$/d' | paste -sd, -)" --body "$body"
```

To walk the whole file, list the IDs first and loop over them —
`awk '/^### [A-F]-/{split($0,a," "); print a[2]}' "$f"` yields all 79 headings; skip `D-10`, which is the
reference table rather than an issue, leaving the 78 findings. Do **not** bulk-create without reading a
couple of rendered issues first: several entries depend on others (`A-13` before `B-6`, `C-1` before
`C-11`, `E-1` together with `F-4`), and one tracking issue per row of the table in section G is usually
the better unit of work than 78 separate ones.







