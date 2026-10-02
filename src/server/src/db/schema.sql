CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS users (
  id text PRIMARY KEY,
  name text NOT NULL,
  avatar_url text,
  role text NOT NULL DEFAULT 'user',
  last_seen_at timestamptz,
  -- Latest power state reported with any location/heartbeat, so the WS
  -- snapshot can show battery badges even right after a server restart.
  battery_level integer,
  is_charging boolean,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_fcm_tokens (
  user_id text NOT NULL REFERENCES users(id),
  token text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, token)
);

-- Long-lived, revocable upload credentials for the native tracking engine.
-- Background uploads can't depend on the short-lived JWT: the app may stay
-- closed for days, and refreshing a rotating refresh token from two places
-- (native engine + Dart auth) races. Only sha256(token) is stored.
CREATE TABLE IF NOT EXISTS devices (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id),
  token_hash text NOT NULL UNIQUE,
  platform text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz,
  revoked_at timestamptz
);

CREATE INDEX IF NOT EXISTS devices_user_idx ON devices (user_id);

CREATE TABLE IF NOT EXISTS viewer_state (
  id text PRIMARY KEY,
  active_viewers integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS location_history (
  id bigserial PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id),
  recorded_at timestamptz NOT NULL,
  location geography(Point, 4326) NOT NULL,
  speed double precision NOT NULL DEFAULT 0,
  heading double precision,
  -- Horizontal accuracy (metres, 68% radius) as reported by the device.
  accuracy double precision,
  -- 'move' | 'trip_start' | 'trip_end' | 'ping' | 'heartbeat' (new engine),
  -- 'foreground' (legacy clients). 'live' points are broadcast-only and never
  -- stored.
  source text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS location_history_user_recorded_at_idx
  ON location_history (user_id, recorded_at DESC);

-- Idempotent re-flush after a partial upload failure.
CREATE UNIQUE INDEX IF NOT EXISTS location_history_user_recorded_uniq
  ON location_history (user_id, recorded_at);

CREATE INDEX IF NOT EXISTS location_history_location_gist_idx
  ON location_history USING GIST (location);
