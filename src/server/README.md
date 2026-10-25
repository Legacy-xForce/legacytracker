# Legacy Tracker — Server

Node.js/TypeScript backend for the Legacy Tracker real-time location sharing app. Built with [Fastify](https://www.fastify.io/) and PostgreSQL (PostGIS).

## Features

- REST API for user profiles
- Batched, idempotent location ingestion from the app's native tracking engine, with WebSocket broadcast to connected viewers
- Live mode: while someone has the map open, devices are pushed (FCM) to stream in realtime; otherwise they batch
- Long-lived device tokens for background uploads, one-time tickets for WebSocket upgrades
- Personal API tokens (`X-API-Token`, read or write) for integrations
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
| `AUTH_JWKS_URI` | `https://auth.legacy-group.tech/.well-known/jwks.json` | Legacy Auth's JWKS, used to verify access tokens. |
| `AUTH_ISSUER` | `https://auth.legacy-group.tech` | `iss` required in access tokens; must match Legacy Auth's `JWT_ISSUER`. |
| `ANDROID_MIN_SUPPORTED_CODE` | `0` | Oldest Android build (`version_code`) still allowed; older builds show "Update required". |
| `AUTH_ALLOWED_CLIENTS` | `tracker-spa,tracker-mobile` | OIDC clients (`client_id`) whose access tokens are accepted, and the `aud` of back-channel logout tokens. |
| `AUTH_MOBILE_CLIENT` | `tracker-mobile` | The only OIDC client allowed to register devices and request Mapbox tokens. |
| `CORS_ALLOWED_ORIGINS` | — | Comma-separated browser origins allowed to call the API. Unset reflects any origin (and logs a warning). |
| `MAPBOX_SECRET_TOKEN` | — | Mapbox secret token with `tokens:write`, `styles:read` and `fonts:read`. Server-side only; mints the app's temporary tokens. The app cannot show a map until this is set. |
| `MAPBOX_USERNAME` | — | Mapbox account that owns the temporary tokens. |
| `MAPBOX_TOKEN_TTL_SECONDS` | `3300` | Lifetime of minted temporary tokens (60–3600). Tokens are cached per user and renewed five minutes before expiry. |

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

The image exposes port `3000` and defines a `HEALTHCHECK` against `/health` for Coolify.

## API reference

All REST endpoints require an `Authorization: Bearer <access_token>` header or an `X-API-Token` header (see [API tokens](#api-tokens)). The access token is verified against Legacy Auth's JWKS (`AUTH_JWKS_URI`), must be ES256 with `iss` = `AUTH_ISSUER`, and comes in one of two shapes while the apps move to OpenID Connect (see `docs/oidc-migration.md`):

- **OpenID Provider tokens** (header `typ: at+jwt`): `aud` must be `tracker` and `client_id` one of `AUTH_ALLOWED_CLIENTS` (otherwise `401`). The RFC 9068 `scope` decides access: `tracker.write` may do anything, `tracker.read` only what a read API token may (otherwise `403 { "error": "This session is read-only" }`), neither is `403`.
- **Legacy password-login tokens**: `type: "access"`, `scopes.tracker: true` (otherwise `403`) and `tracker` in `aud` (otherwise `401`, e.g. for a token issued for the calendar). They have full access.

The user identity is taken from the `sub` claim. When a user row is created, the server stores the human-readable display name from the token claims (`display_name`, then `name`, then the login username) when available, instead of defaulting to the UUID subject.

The web app renders this reference, with examples, from the OpenAPI document in `src/web/src/lib/openapi.ts` using Scalar at `/docs`.

### API tokens

Personal tokens for integrations: they act as the user who created them, never
expire and don't rotate by themselves. Send one as
`X-API-Token: legacy-tracker-01a15968-64aa-707d-8904-a6a408611289`; it takes
precedence over `Authorization`.

- `read` tokens may make every `GET` request plus `POST /api/v1/streams/ticket`
  (their WebSocket stream ignores uploads). Anything else is `403 { "error": "This API token is read-only" }`.
- `write` tokens may do anything the user's session can, except the
  session-only routes below (`403`).
- Token management, `POST /api/v1/devices` and `POST /api/v1/fcm-token` need a
  signed-in session, so a leaked token can't mint replacements.
- Only `sha256(token)` is stored: the value is shown once, at creation or
  rotation. Up to 25 tokens per user.
- Removing someone's tracker access also ends their integrations: a
  back-channel logout reporting lost access (see [Sign-out](#sign-out-back-channel-logout))
  deletes that user's tokens, as does a legacy JWT that lacks `scopes.tracker`.

| Method   | Path                              | Auth | Description |
|----------|-----------------------------------|------|-------------|
| `GET`    | `/api/v1/api-tokens`              | JWT  | `{ "tokens": [{ "id", "name", "scope", "token_hint", "created_at", "last_used_at", "rotated_at" }] }`, newest first. |
| `POST`   | `/api/v1/api-tokens`              | JWT  | Body `{ "name"?: "Home Assistant", "scope": "read" \| "write" }`. `201` with the summary plus `token`. `400` on a bad scope or at the limit. |
| `POST`   | `/api/v1/api-tokens/:id/rotate`   | JWT  | Replaces the value (the old one stops working at once); returns the summary plus the new `token`. `404` if not yours. |
| `DELETE` | `/api/v1/api-tokens/:id`          | JWT  | `{ "deleted": true }`, or `404`. |

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
| `POST`   | `/api/v1/devices`       | JWT  | Body `{ "platform": "android", "replaces": "<old device id>" }` (both optional). Returns `{ "device_id", "device_token" }`; `replaces` revokes the old token. OpenID Provider tokens must come from `AUTH_MOBILE_CLIENT` (the app), otherwise `403`. |
| `DELETE` | `/api/v1/devices/:id`   | JWT, write API token, or that device's own token | Revokes the token (sign-out). |

Only `sha256(token)` is stored.

### Mapbox tokens

Release builds of the phone app contain no Mapbox token. Before creating the
map they ask the tracker for a short-lived temporary token, which the server
mints with its `MAPBOX_SECRET_TOKEN` and caches per user until five minutes
before expiry.

| Method | Path                     | Auth | Description |
|--------|--------------------------|------|-------------|
| `POST` | `/api/v1/mapbox/token`   | JWT  | Session-only; OpenID Provider tokens must come from `AUTH_MOBILE_CLIENT` (the app), otherwise `403`. Returns `{ "token": "tk.…", "expires_at": "2026-10-25T13:00:00.000Z" }` with `Cache-Control: no-store`. `503` when `MAPBOX_SECRET_TOKEN`/`MAPBOX_USERNAME` are not configured or Mapbox refuses the request. |

The endpoint refuses API tokens and never logs the minted token or the secret.
Temporary tokens cannot be revoked or restricted to URLs, so they expire within
an hour and are renewed ahead of time; see [`docs/mapbox.md`](../../docs/mapbox.md).

### App updates

| Method | Path                          | Auth | Description |
|--------|-------------------------------|------|-------------|
| `GET`  | `/api/v1/app/android/latest`  | none | The current Android release: `{ "version_code", "version_name", "apk_url", "sha256", "size", "notes", "published_at", "min_supported_code" }` (builds below `min_supported_code` must update first), or 204 when none is published. |

Releases are GitHub releases tagged `android-v<name>+<code>`, read every five
minutes; a new one is announced to every device with an FCM `lt_cmd: update`
push. See [`docs/app-updates.md`](../../docs/app-updates.md).

### Location

| Method | Path                    | Description                                                                  |
|--------|-------------------------|------------------------------------------------------------------------------|
| `POST` | `/api/v1/location`      | Ingest one or more points. Auth: `Bearer <JWT>`, `Device <token>` or a write API token. |
| `POST` | `/api/v1/users/:userId/location-refresh` | Wakes that user's phone for a fresh fix and waits (up to 25 s) for it to report in. `200` with their roster entry, `504 device_unreachable`, `403 not_sharing`, `409 no_device`, `404`. Auth: `Bearer <JWT>` or a write API token. |

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
  "is_charging": false,
  "tracking_issues": ["battery_optimization"]
}
```

`tracking_issues` (optional): the phone settings that currently block or delay
location updates, sent by the device on the newest point of an upload. Codes:
`location_services_off`, `location_permission`, `background_location`,
`precise_location`, `battery_optimization`; unknown codes are dropped. `[]`
means nothing is wrong; leaving the field out (older builds) keeps the last
report. Stored in `users.tracking_issues` and sent to viewers as
`tracking_issues` on snapshot entries and live/presence updates (never in the
redacted entry of a user who hides from the viewer). See
`services/tracking-issues.ts`.

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

### Travel leaderboard

| Method | Path | Description |
|---|---|---|
| `GET`  | `/api/v1/leaderboard` | Query `from`, `to` (ISO 8601, both required; windows are capped at 366 days). Returns `{ "from", "to", "entries": [...] }`, furthest first: `user_id`, `username`, `rank` (equal distances share one), `distance_meters`, `duration_seconds` (time on trips), `avg_speed` (distance over that time), `top_speed` (m/s) and `trip_count`. Built from the same trips as `/api/v1/history`, so drift while parked doesn't count. Only people with a trip in the window are listed, plus the caller; people who hide their location from the caller are left out. |

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
{ "user_id": "alice", "latitude": 45.07, "longitude": 7.68, "speed": 12.5, "heading": 270, "recorded_at": "...", "here_since": "...", "battery_level": 81, "is_charging": false, "tracking_issues": [], "last_seen_at": "..." }
```

**Presence update** (same position, or an older batch arriving late): the same
message without coordinates — refreshes `last_seen_at`, `here_since` and
battery only.

**Signed out** (just before the server closes the socket, after a back-channel
logout for the session that opened it): `{ "type": "signed_out" }`. Clients
drop their tokens and show the sign-in screen.

#### WebSocket messages (client → server)

`{ "type": "map_active", "active": true }` — whether this viewer's map is on
screen; drives live mode.

### Sign-out (back-channel logout)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/auth/backchannel-logout` | Called by Legacy Auth, not by clients. Form body `logout_token=<JWT>` ([OIDC Back-Channel Logout](https://openid.net/specs/openid-connect-backchannel-1_0.html)): ES256 from `AUTH_ISSUER`, `typ: logout+jwt`, `aud` one of `AUTH_ALLOWED_CLIENTS`, at most 5 min old, the back-channel `events` member, no `nonce`. `200`, or `400` for an invalid token. |

A token with `sid` closes the WebSocket streams opened with that OP session
(`signed_out` message); one with only `sub` closes all of the user's
session streams (API-token streams stay). When `events` also holds
`urn:legacy:event:access-revoked` (the account lost the tracker scope or was
disabled), the user's API tokens are deleted and all of their streams close.

## Project layout

```
src/
  app.ts                  # Fastify app, routes, startup
  config/db.ts            # PostgreSQL connection pool
  db/schema.sql           # Database schema (apply once)
  services/
    api-tokens.ts         # personal API tokens (X-API-Token) and their scopes
    connection-manager.ts # WebSocket client registry & broadcast
    device-auth.ts        # device tokens for background uploads
    dwell-tracker.ts      # "here since" for each user's current stay
    fcm-service.ts        # tracking commands via FCM
    live-controller.ts    # live-mode state (debounce, renewal, TTL)
    session-builder.ts    # trips for history/replay
    history-range.ts      # from/to validation for deleting history
    leaderboard.ts        # travel totals and ranking for the leaderboard
test/                     # node:test unit tests (npm test)
```
