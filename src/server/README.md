# Legacy Tracker — Server

Node.js/TypeScript backend for the Legacy Tracker real-time location sharing app. Built with [Fastify](https://www.fastify.io/) and PostgreSQL (PostGIS).

## Features

- REST API for user profiles and notifications
- Real-time location ingestion with WebSocket broadcast to connected viewers
- Adaptive pacing: tells the client to report aggressively when viewers are connected, passively when none are
- One-time ticket auth for WebSocket upgrades

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

### 3. Run

```bash
# development (ts-node, no build step)
npm run dev

# production
npm run build
npm start
```

### Docker

```bash
docker build -t legacytracker-server .
docker run -p 3000:3000 -e DATABASE_URL=<url> legacytracker-server
```

## API reference

All REST endpoints require an `Authorization: Bearer <access_token>` header. The token is verified against the JWKS endpoint at `https://auth.legacy-group.tech/.well-known/jwks.json` and the user identity is taken from the `sub` claim. Users are created on first request.

### Profile

| Method  | Path               | Description                        |
|---------|--------------------|------------------------------------|
| `GET`   | `/api/v1/profile`  | Fetch the current user's profile   |
| `PATCH` | `/api/v1/profile`  | Update `name` and/or `avatar_url`  |

### Notifications

| Method | Path                           | Description                         |
|--------|--------------------------------|-------------------------------------|
| `GET`  | `/api/v1/notifications`        | List notifications (newest first)   |
| `POST` | `/api/v1/notifications/read`   | Mark a notification as read (`{ "notification_id": <id> }`) |

### Location

| Method | Path                    | Description                                                                  |
|--------|-------------------------|------------------------------------------------------------------------------|
| `POST` | `/api/v1/location`      | Ingest one or more location points. Returns `X-Pacing-Mode` header (`AGGRESSIVE` / `PASSIVE`). |

Request body (single object or array):

```json
{
  "coords": {
    "latitude": 45.0703,
    "longitude": 7.6869,
    "speed": 12.5,
    "heading": 270
  },
  "timestamp": "2026-06-13T10:00:00.000Z"
}
```

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

**Live update** (broadcast on each location POST):

```json
{ "user_id": "alice", "latitude": 45.07, "longitude": 7.68, "speed": 12.5, "heading": 270, "recorded_at": "..." }
```

## Project layout

```
src/
  app.ts                  # Fastify app, routes, startup
  config/db.ts            # PostgreSQL connection pool
  db/schema.sql           # Database schema (apply once)
  services/
    connection-manager.ts # WebSocket client registry & broadcast
```
