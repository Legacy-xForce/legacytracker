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

### 3. Run

```bash
# development (ts-node, no build step)
npm run dev

# production
npm run build
npm start

# unit tests (session building, live-mode controller)
npm test
```

Schema changes are applied idempotently at startup by `ensureBackendSchema()`.

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

### Location

| Method | Path                    | Description                                                                  |
|--------|-------------------------|------------------------------------------------------------------------------|
| `POST` | `/api/v1/location`      | Ingest one or more points. Auth: `Bearer <JWT>` or `Device <token>`. |

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
    { "user_id": "alice", "latitude": 45.07, "longitude": 7.68, "speed": 0, "heading": null, "recorded_at": "..." }
  ]
}
```

The snapshot uses each user's newest point (in memory or the latest stored row),
so it is complete right after a restart.

**Live update** (broadcast on ingest when a user's newest point moved forward):

```json
{ "user_id": "alice", "latitude": 45.07, "longitude": 7.68, "speed": 12.5, "heading": 270, "recorded_at": "...", "battery_level": 81, "is_charging": false, "last_seen_at": "..." }
```

**Presence update** (same position, or an older batch arriving late): the same
message without coordinates — refreshes `last_seen_at` and battery only.

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
    fcm-service.ts        # tracking commands via FCM
    live-controller.ts    # live-mode state (debounce, renewal, TTL)
    session-builder.ts    # trips for history/replay
test/                     # node:test unit tests (npm test)
```
