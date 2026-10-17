# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Legacy Tracker is a real-time location-sharing app, a monorepo with three independent packages under `src/`:

| Package | Stack | Role |
|---|---|---|
| `src/client` | Flutter (Dart) + native Kotlin/Swift | Phone app. A **native** tracking engine records and uploads positions; Flutter is only the UI. |
| `src/server` | Fastify + TypeScript, PostgreSQL/PostGIS | REST + WebSocket API, live-mode controller, FCM pushes, Android release feed. |
| `src/web` | Vue 3, Vite, Tailwind 4, Pinia, Leaflet | Read-only browser map; never shares the viewer's own location. |

Design docs live in `docs/` (`location-tracking.md` is the key one; also `app-updates.md`, `calendar-events.md`, `web-app.md`) and `src/server/README.md` holds the full API reference. Read them before changing the matching area.

## Commands

Server (`src/server`; `npm` and `bun` lockfiles both exist, CI/Docker use npm):
```bash
npm run dev                      # ts-node src/app.ts
npm run build && npm start       # tsc -> dist/app.js
npm test                         # node:test via ts-node/register, test/*.test.ts
node --require ts-node/register --test test/dwell-tracker.test.ts   # single test file
```
Schema is `src/db/schema.sql` plus idempotent changes applied at startup by `ensureBackendSchema()` in `src/app.ts`.

Web (`src/web`; CI runs `format:check`, `test`, `build` on Node 22):
```bash
npm run dev                      # http://localhost:5173
npm test                         # vitest (jsdom)
npx vitest run src/test/peers.test.ts   # single test file
npm run format:check             # prettier; `npm run format` to fix
npm run build                    # vue-tsc -b && vite build
```
Production services are used unless overridden by `VITE_BACKEND_URL`, `VITE_AUTH_URL`, `VITE_CALENDAR_URL`, `VITE_CALENDAR_WEB_URL` (see `.env.example`).

Client (`src/client`; Flutter 3.44, Dart ^3.12):
```bash
flutter pub get
flutter analyze                  # flutter_lints
flutter test                     # Dart tests in test/
flutter test test/sharing_test.dart
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:3000   # debug/profile only
flutter run -t lib/main_mapcheck.dart -d <device>            # standalone map harness, no login/backend
cd android && ./gradlew testDebugUnitTest                    # Kotlin engine tests (PathSampler, StopDetector, DriveSimulation)
```
`test-location.mjs` (repo root) simulates a GPS drive against a server (`--server http://localhost:3000`).

Releasing Android: bump the build number after `+` in `src/client/pubspec.yaml`, then `scripts/release-android.sh` (or the `Release Android` workflow). Phones only install a higher build number, and every release must be signed with the same key (`android/release-signing-cert.sha256`).

## Architecture

### Tracking pipeline (spans client, server, FCM)
- The engine is native (`android/.../tracking/`, `ios/Runner/TrackingEngine.swift`) and runs with no Flutter engine: stationary (no GPS) -> moving (GPS, `PathSampler` line simplification -> local queue) -> stationary (`StopDetector`). It uploads in batches with a long-lived **device token** (rotated every 24 h through upload responses; a replaced token coming back revokes the device), immediately while "live". Dart's `tracking_engine.dart` is just the method/event-channel bridge for the UI.
- **Live mode**: devices stream in realtime only while some viewer has a map open. Clients send `{type:"map_active"}` over the WebSocket; `live-controller.ts` debounces/renews that state and `fcm-service.ts` pushes `lt_cmd: live|idle` data messages to all registered devices. `POST /api/v1/location` replies with `live_ttl_s`. `source: "live"` points are broadcast but **never stored**; inserts are idempotent on `(user_id, recorded_at)`.
- Server keeps per-user state in memory (last location, "here since" via `dwell-tracker.ts`, viewer presence) but WebSocket snapshots fall back to stored rows so a restart is safe. `session-builder.ts` turns stored points into trips for history/replay.
- Auth is Legacy Auth (separate service, `auth.legacy-group.tech`): the server verifies JWTs against its JWKS and takes identity from `sub`. WebSocket access uses single-use tickets (`POST /api/v1/streams/ticket`), not the JWT.
- Android self-update: the server polls GitHub releases tagged `android-v<name>+<code>` every 5 min, serves `/api/v1/app/android/latest`, and pushes `lt_cmd: update`; the app installs via `PackageInstaller` (`android/.../updates/`).

### Client structure (`src/client/lib`)
`provider`-based. `data/network/` has one service per API area plus the `Backend` interface (realtime peers/viewers) with `RemoteBackend` (used by `app.dart`) and `MockBackend`; `data/models/` are plain models; `features/<area>/` hold screens, providers and widgets. Native code is in `android/app/src/main/kotlin/com/legacy/legacytracker/` (`tracking/`, `updates/`).
### Web structure (`src/web/src`)
`api/` (REST + WebSocket clients), `stores/` (Pinia: session, peers, history, checkpoints, events, sharing), `lib/` (pure logic: clustering, replay, geocoding throttle, presence), `components/`. Markers are Vue components mounted into Leaflet markers and patched in place; pan followed points with `panBy`, not `setView`/`panTo` (an unanimated view reset drops all tiles).

### Cross-cutting rules worth knowing
- **Access scopes**: the server returns 403 for JWTs without `scopes.tracker`; disabled accounts are detected from Legacy Auth's 403 `Account disabled` on login/refresh. Both clients have "Scope required" / "Access restricted" screens. Device-token uploads are **not** scope-checked. Calendar features need `scopes.calendar` and are hidden without it.
- **Nominatim** is shared by street names, place search and event geocoding: one request per 1.1 s, results cached (SharedPreferences / `localStorage`).
- Release builds of the app **ignore** `BACKEND_URL`/`CALENDAR_URL`/`CALENDAR_WEB_URL` and always use production (`kReleaseMode` in `core/constants.dart`); the calendar web link base is kept in sync in `AppConstants.calendarWebUrl` and `src/web/src/config.ts`.

## Gotchas

- `src/server/.env` points at the **shared cloud database and a live Firebase key**. Running the server with it writes to shared history, and opening any map sends "go live" pushes to every registered phone. For local work use a throwaway PostGIS (e.g. PGlite) via `DATABASE_URL` and set `FIREBASE_SERVICE_ACCOUNT_JSON=''`. The same applies when pointing the web app or emulator at a local server.
- Pushing to `main` makes CI publish the server image as ghcr `:latest`, so server changes (especially auth) can go live on push.
- The Android emulator reaches the host at `10.0.2.2`; debug builds allow cleartext HTTP, release builds do not.
