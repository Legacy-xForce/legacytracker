# Legacy Tracker — Server

Node.js/TypeScript backend for the Legacy Tracker real-time location sharing app. Built with [Fastify](https://www.fastify.io/) and PostgreSQL (PostGIS).

## Features

- REST API for user profiles
- Batched, idempotent location ingestion from the app's native tracking engine, with WebSocket broadcast to connected viewers
- Live mode: while someone has the map open, devices are pushed (FCM) to stream in realtime; otherwise they batch
- Long-lived device tokens for background uploads, one-time tickets for WebSocket upgrades
- Trip/session history for replay

See [`docs/location-tracking.md`](../../docs/location-tracking.md) for the end-to-end design.

## Requirements

- Node.js ≥ 18
- PostgreSQL with the **PostGIS** extension

## Getting started

### 1. Apply the database schema

```bash
psql $DATABASE_URL -f src/db/schema.sql
```

### 2. Configure environment

Create a `.env` file (or export variables):

| Variable       | Default                                    | Description              |
|----------------|--------------------------------------------|--------------------------|
| `DATABASE_URL` | `postgres://localhost:5432/legacytracker`  | PostgreSQL connection URL |
| `PORT`         | `3000`                                     | HTTP/WS listen port      |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | — | Service-account JSON for FCM tracking commands (live mode). Without it devices only batch. |
| `ANDROID_RELEASES_REPO` | `Legacy-xForce/legacytracker` | GitHub repository whose `android-v*` releases the app updates itself from. Empty disables update checks. |
| `GITHUB_TOKEN` | — | Optional; raises GitHub's API rate limit for the release lookups. |

### 3. Run

```bash
# development (ts-node, no build step)
npm run dev

# production
npm run build
npm start

# unit tests (session building, live-mode controller, dwell tracking)
npm test
```

Schema changes are applied idempotently at startup by `ensureBackendSchema()`.

### Running the app against a local server

The app talks to production unless built with `BACKEND_URL`. From the Android
emulator the host machine is `10.0.2.2` (debug builds allow cleartext HTTP):

```bash
cd src/client
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:3000
```

Leave `FIREBASE_SERVICE_ACCOUNT_JSON` empty when pointing a dev server at a
shared database: with it set, opening the map sends "go live" pushes to every
registered device.

### Docker

```bash
docker build -t legacytracker-server .
docker run -p 3000:3000 -e DATABASE_URL=<url> legacytracker-server
```

## API reference

All REST endpoints require an `Authorization: Bearer <access_token>` header. The token is verified against the JWKS endpoint at `https://auth.legacy-group.tech/.well-known/jwks.json` and the user identity is taken from the `sub` claim. When a user row is created, the server stores the human-readable username from the token claims when available, instead of defaulting to the UUID subject.

### Profile

| Method  | Path               | Description                        |
|---------|--------------------|------------------------------------|
| `GET`   | `/api/v1/profile`  | Fetch the current user's profile   |
| `PATCH` | `/api/v1/profile`  | Update `name` and/or `avatar_url`  |

### Devices

The app's native tracking engine uploads while the app is closed, so it uses a
long-lived device token instead of the user JWT.

| Method   | Path                    | Auth | Description |
|----------|-------------------------|------|-------------|
| `POST`   | `/api/v1/devices`       | JWT  | Body `{ "platform": "android", "replaces": "<old device id>" }` (both optional). Returns `{ "device_id", "device_token" }`; `replaces` revokes the old token. |
| `DELETE` | `/api/v1/devices/:id`   | JWT, or that device's own token | Revokes the token (sign-out). |

Only `sha256(token)` is stored.

### App updates

| Method | Path                          | Auth | Description |
|--------|-------------------------------|------|-------------|
| `GET`  | `/api/v1/app/android/latest`  | none | The current Android release: `{ "version_code", "version_name", "apk_url", "sha256", "size", "notes", "published_at" }`, or 204 when none is published. |

Releases are GitHub releases tagged `android-v<name>+<code>`, read every five
minutes; a new one is announced to every device with an FCM `lt_cmd: update`
push. See [`docs/app-updates.md`](../../docs/app-updates.md).

### Location

| Method | Path                    | Description                                                                  |
|--------|-------------------------|------------------------------------------------------------------------------|
| `POST` | `/api/v1/location`      | Ingest one or more points. Auth: `Bearer <JWT>` or `Device <token>`. |
| `POST` | `/api/v1/users/:userId/location-refresh` | Wakes that user's phone for a fresh fix and waits (up to 25 s) for it to report in. `200` with their roster entry, `504 device_unreachable`, `403 not_sharing`, `409 no_device`, `404`. Auth: `Bearer <JWT>`. |

Request body (single object or array, any order):

```json
{
  "coords": {
    "latitude": 45.0703,
    "longitude": 7.6869,
    "speed": 12.5,
    "heading": 270,
    "accuracy": 4.8
  },
  "timestamp": "2026-06-13T10:00:00.000Z",
  "source": "move",
  "battery_level": 81,
  "is_charging": false
}
```

`source`: `trip_start` / `move` / `trip_end` (recorded path), `ping` (on-demand
fix), `heartbeat` (parked liveness), `live` (realtime while watched — broadcast
only, **never stored**). Inserts are idempotent on `(user_id, recorded_at)`.

Response: `{ "received", "stored", "pacing", "live_ttl_s" }` — `live_ttl_s > 0`
tells the device to stream realtime for that long. The `X-Pacing-Mode` header
is kept for older builds.

### Tracking commands (FCM)

Data-only messages sent to every registered token when live mode changes:
`{ "type": "tracking_command", "lt_cmd": "live" | "idle", "lt_ttl": "600", "pacing": … }`.
`live` goes out at high priority (60 s TTL) when the first viewer opens the
map and is renewed every 4 min; `idle` follows 45 s after the last viewer
leaves. iOS uses background pushes (`apns-push-type: background`, priority 5).
Tokens FCM reports as unregistered are pruned.

### History

| Method | Path              | Description |
|--------|-------------------|-------------|
| `GET`  | `/api/v1/history` | Query `user_id` (default: caller), `from`, `to` (ISO 8601). Returns `{ "sessions": [...] }`: trips with `start_at`, `end_at`, `duration_seconds`, `distance_meters`, `avg_speed`, `top_speed`, `point_count` and `points`. With `points=false` the points are left out — the app's trip calendar fetches a month of summaries that way. Windows are capped at 30 days (93 without points). |
| `DELETE` | `/api/v1/history` | Query `from`, `to` (ISO 8601, both required, both inclusive). Erases the **caller's own** stored points in that window and returns `{ "deleted": n }`. A trip is deleted with its `start_at`..`end_at`, a day with its whole local day; trips aren't stored, they are derived from the points. There is no `user_id`: nobody can delete someone else's history. Needs a signed-in user (not a device token); windows are capped at 30 days. |

### WebSocket stream

| Method | Path               | Description                                       |
|--------|--------------------|---------------------------------------------------|
| `POST` | `/api/v1/streams/ticket` | Issue a single-use ticket (60 s TTL). Returns `{ "ticket": "<uuid>" }`. |
| `GET`  | `/api/v1/stream?ticket=<uuid>` | Upgrade to WebSocket. Receives a `snapshot` message on connect, then live location updates. |

#### WebSocket messages (server → client)

**Snapshot** (sent once on connect):

```json
{
  "type": "snapshot",
  "users": [
    { "user_id": "alice", "latitude": 45.07, "longitude": 7.68, "speed": 0, "heading": null, "recorded_at": "...", "here_since": "..." }
  ]
}
```

The snapshot uses each user's newest point (in memory or the latest stored row),
so it is complete right after a restart.

`here_since` is when the user arrived where they are now (the app's "Here
for"): the start of the run of points within 100 m of each other with no trip
point in between. It is `null` until a user has any location. The newest
point's `recorded_at` can't serve: a parked phone still sends fresh fixes while
someone watches. See `services/dwell-tracker.ts`.

**Live update** (broadcast on ingest when a user's newest point moved forward):

```json
{ "user_id": "alice", "latitude": 45.07, "longitude": 7.68, "speed": 12.5, "heading": 270, "recorded_at": "...", "here_since": "...", "battery_level": 81, "is_charging": false, "last_seen_at": "..." }
```

**Presence update** (same position, or an older batch arriving late): the same
message without coordinates — refreshes `last_seen_at`, `here_since` and
battery only.

#### WebSocket messages (client → server)

`{ "type": "map_active", "active": true }` — whether this viewer's map is on
screen; drives live mode.

## Project layout

```
src/
  app.ts                  # Fastify app, routes, startup
  config/db.ts            # PostgreSQL connection pool
  db/schema.sql           # Database schema (apply once)
  services/
    connection-manager.ts # WebSocket client registry & broadcast
    device-auth.ts        # device tokens for background uploads
    dwell-tracker.ts      # "here since" for each user's current stay
    fcm-service.ts        # tracking commands via FCM
    live-controller.ts    # live-mode state (debounce, renewal, TTL)
    session-builder.ts    # trips for history/replay
    history-range.ts      # from/to validation for deleting history
test/                     # node:test unit tests (npm test)
```
