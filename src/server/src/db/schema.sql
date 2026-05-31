CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS users (
  id text PRIMARY KEY,
  name text NOT NULL,
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT now()
);

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
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS location_history_user_recorded_at_idx
  ON location_history (user_id, recorded_at DESC);

CREATE INDEX IF NOT EXISTS location_history_location_gist_idx
  ON location_history USING GIST (location);
