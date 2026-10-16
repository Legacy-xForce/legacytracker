import "dotenv/config";
import crypto from "crypto";
import Fastify, { FastifyReply, FastifyRequest } from "fastify";
import cors from "@fastify/cors";
import websocket from "@fastify/websocket";
import { createRemoteJWKSet, jwtVerify, errors as joseErrors, type JWTPayload } from "jose";
import pool from "./config/db";
import { AndroidReleaseSource } from "./services/app-releases";
import {
  canModifyCheckpoint,
  validateCheckpointInput,
} from "./services/checkpoints";
import ConnectionManager from "./services/connection-manager";
import { DeviceAuth } from "./services/device-auth";
import {
  advanceDwell,
  DWELL_MAX_SPEED,
  DWELL_RADIUS_METERS,
  DWELL_SEED_SQL,
  dwellFromSeedRow,
  TRIP_SOURCES,
  type Dwell,
  type DwellSeedRow,
} from "./services/dwell-tracker";
import {
  initializeFcm,
  sendAppUpdateNotice,
  sendRefreshCommand,
  sendTrackingCommand,
} from "./services/fcm-service";
import { LiveController, type TrackingCommand } from "./services/live-controller";
import { LocationRefreshCoordinator } from "./services/location-refresh";
import { ViewerPresence } from "./services/viewer-presence";
import { parseHistoryRange } from "./services/history-range";
import { buildSessions, type HistoryPoint } from "./services/session-builder";
import {
  messageFor,
  redactedEntry,
  SharingRegistry,
} from "./services/sharing";
import { hasTrackerScope } from "./services/tracker-scope";

const JWKS = createRemoteJWKSet(
  new URL("https://auth.legacy-group.tech/.well-known/jwks.json"),
  {
    timeoutDuration: 5000,
  },
);

const app = Fastify({
  logger: {
    level: process.env.LOG_LEVEL ?? "info",
    transport: {
      target: "pino-pretty",
      options: {
        colorize: process.env.LOG_COLOR !== "false",
        translateTime: "yyyy-mm-dd HH:MM:ss.l",
        ignore: "pid,hostname",
      },
    },
  },
});
const connectionManager = new ConnectionManager();
const deviceAuth = new DeviceAuth(pool);
const sharing = new SharingRegistry();
const tickets = new Map<string, TicketEntry>();
const lastKnownLocation = new Map<string, KnownLocation>();
const lastKnownName = new Map<string, string>();
// Each user's current stay ("here since"), seeded from stored history the
// first time a user is needed and advanced with every point after that.
const dwellByUser = new Map<string, Dwell | null>();
const STATE_ID = "foreground";
const DEFAULT_HISTORY_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_HISTORY_WINDOW_MS = 30 * 24 * 60 * 60 * 1000;
// Without points (calendar summaries) a request is cheap to answer, so a
// whole calendar month — or a few — fits in one call.
const MAX_SUMMARY_WINDOW_MS = 93 * 24 * 60 * 60 * 1000;

// Live mode: devices stream in realtime only while someone has the map open.
// `live` expires on the device after LIVE_TTL_SECONDS unless renewed, so a
// lost `idle` push can't leave phones streaming indefinitely.
const LIVE_TTL_SECONDS = 600;
const LIVE_RENEW_INTERVAL_MS = 4 * 60_000;
const LIVE_OFF_DEBOUNCE_MS = 45_000;

// "Force location update": how long a viewer's request waits for the target's
// phone to report in. A woken phone needs up to ~15 s for a GPS fix.
const REFRESH_TIMEOUT_MS = 25_000;

// Who is looking at the map, shown to everyone. A face appears once a map has
// been open briefly and stays through a reconnect; see ViewerPresence.
const VIEWER_JOIN_SETTLE_MS = 500;
const VIEWER_LEAVE_GRACE_MS = 3_000;
// Sockets that miss a ping are dropped on the next round, so a viewer whose
// connection died silently disappears within two intervals.
const HEARTBEAT_INTERVAL_MS = 25_000;

// Android self-update: releases are read from GitHub (see
// services/app-releases.ts). An empty ANDROID_RELEASES_REPO turns it off.
const ANDROID_RELEASES_REPO =
  process.env.ANDROID_RELEASES_REPO ?? "Legacy-xForce/legacytracker";
const RELEASE_CHECK_INTERVAL_MS = 5 * 60_000;
// Just under the check interval, so every check sees fresh data.
const RELEASE_CACHE_TTL_MS = 4 * 60_000;

const PacingMode = {
  AGGRESSIVE: "AGGRESSIVE",
  PASSIVE: "PASSIVE",
} as const;

type PacingMode = (typeof PacingMode)[keyof typeof PacingMode];

interface TicketEntry {
  userId: string;
  displayName: string;
  expiresAt: number;
  used: boolean;
}

interface KnownLocation {
  latitude: number;
  longitude: number;
  speed: number;
  heading: number | null;
  accuracy: number | null;
  recordedAt: string;
  batteryLevel: number | null;
  isCharging: boolean | null;
  source: string | null;
}

interface LocationPayload {
  coords?: {
    latitude?: number;
    longitude?: number;
    speed?: number;
    heading?: number;
    accuracy?: number;
  };
  timestamp?: string;
  battery_level?: number;
  is_charging?: boolean;
  source?: string;
}

// The web client calls from its own origin: every method a route uses must be
// listed, or the browser blocks the request (PUT /api/v1/sharing/:viewerId).
app.register(cors, {
  origin: true,
  methods: ["GET", "POST", "PUT", "PATCH", "DELETE"],
});
app.register(websocket);

/** Sends one push to every registered device, pruning dead tokens. */
async function pushToAllDevices(
  send: (tokens: string[]) => Promise<string[]>,
): Promise<{ devices: number; pruned: number }> {
  const result = await pool.query<{ token: string }>(
    "SELECT token FROM user_fcm_tokens",
  );
  const tokens = result.rows.map((r) => r.token);
  const invalid = await send(tokens);
  if (invalid.length > 0) {
    await pool.query("DELETE FROM user_fcm_tokens WHERE token = ANY($1)", [
      invalid,
    ]);
  }
  return { devices: tokens.length, pruned: invalid.length };
}

async function sendLiveCommand(
  command: TrackingCommand,
  ttlSeconds: number,
): Promise<void> {
  const sent = await pushToAllDevices((tokens) =>
    sendTrackingCommand(tokens, command, ttlSeconds),
  );
  app.log.info({ command, ttlSeconds, ...sent }, "[live] sent tracking command");
}

// Every connected viewer sees every driver's pin on the same live map —
// there's no per-driver subscription — so live mode is scoped to "is
// anyone's map tab actually in the foreground right now", not merely "is
// anyone connected at all".
const liveController = new LiveController({
  ttlSeconds: LIVE_TTL_SECONDS,
  renewIntervalMs: LIVE_RENEW_INTERVAL_MS,
  offDebounceMs: LIVE_OFF_DEBOUNCE_MS,
  send: sendLiveCommand,
  onError: (error) =>
    app.log.warn({ error }, "Unable to send tracking command via FCM"),
});

/** Pushes `refresh` to one user's devices, pruning dead tokens. */
async function sendRefreshToUser(userId: string): Promise<void> {
  const { rows } = await pool.query<{ token: string }>(
    "SELECT token FROM user_fcm_tokens WHERE user_id = $1",
    [userId],
  );
  const tokens = rows.map((r) => r.token);
  const invalid = await sendRefreshCommand(tokens);
  if (invalid.length > 0) {
    await pool.query("DELETE FROM user_fcm_tokens WHERE token = ANY($1)", [
      invalid,
    ]);
  }
  app.log.info(
    { userId, devices: tokens.length, pruned: invalid.length },
    "[refresh] sent refresh command",
  );
}

const locationRefresh = new LocationRefreshCoordinator({
  timeoutMs: REFRESH_TIMEOUT_MS,
  send: sendRefreshToUser,
  onError: (error) =>
    app.log.warn({ error }, "Unable to send refresh command via FCM"),
});

// Everyone sees everyone looking at the map, themselves included.
const viewerPresence = new ViewerPresence({
  joinSettleMs: VIEWER_JOIN_SETTLE_MS,
  leaveGraceMs: VIEWER_LEAVE_GRACE_MS,
  onChange: (viewerIds) => {
    app.log.info({ viewerIds }, "[viewers] map viewers changed");
    connectionManager.broadcast(viewersMessage());
  },
});

function viewersMessage() {
  return {
    type: "viewers",
    viewers: viewerPresence.viewerIds.map((id) => ({
      id,
      name: lastKnownName.get(id) ?? id,
    })),
  };
}

const androidReleases = ANDROID_RELEASES_REPO
  ? new AndroidReleaseSource({
      repo: ANDROID_RELEASES_REPO,
      token: process.env.GITHUB_TOKEN || undefined,
      ttlMs: RELEASE_CACHE_TTL_MS,
    })
  : null;

// Highest Android version code seen since startup. The first lookup only
// records it: devices that missed a release while the server was down still
// find it on their own periodic check.
let announcedAndroidVersion: number | null = null;

async function announceNewAndroidRelease(): Promise<void> {
  if (!androidReleases) {
    return;
  }
  try {
    const release = await androidReleases.latest();
    if (!release) {
      return;
    }
    if (
      announcedAndroidVersion !== null &&
      release.versionCode > announcedAndroidVersion
    ) {
      const sent = await pushToAllDevices((tokens) =>
        sendAppUpdateNotice(tokens, release.versionCode),
      );
      app.log.info(
        { versionCode: release.versionCode, ...sent },
        "[updates] announced new Android release",
      );
    }
    announcedAndroidVersion = Math.max(
      announcedAndroidVersion ?? 0,
      release.versionCode,
    );
  } catch (error) {
    app.log.warn({ error }, "[updates] unable to check Android releases");
  }
}

function getPacingMode(): PacingMode {
  return liveController.isActive ? PacingMode.AGGRESSIVE : PacingMode.PASSIVE;
}

async function updateViewerState(): Promise<void> {
  liveController.update(connectionManager.activeMapCount);
  viewerPresence.update(connectionManager.activeMapUsers());
  try {
    await pool.query(
      `INSERT INTO viewer_state (id, active_viewers)
       VALUES ($1, $2)
       ON CONFLICT (id)
       DO UPDATE SET active_viewers = EXCLUDED.active_viewers, updated_at = now()`,
      [STATE_ID, connectionManager.count],
    );
  } catch (error) {
    app.log.warn({ error }, "Unable to synchronize viewer state with database");
  }
}

function normalizeNumber(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  return value;
}

function readStringClaim(payload: JWTPayload, claim: string): string | null {
  const value = payload[claim];
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function getDisplayNameFromToken(
  payload: JWTPayload,
  fallbackId: string,
): string {
  const candidates = [
    readStringClaim(payload, "preferred_username"),
    readStringClaim(payload, "username"),
    readStringClaim(payload, "nickname"),
    readStringClaim(payload, "name"),
    readStringClaim(payload, "email"),
  ];

  return (
    candidates.find(
      (candidate) => candidate != null && candidate !== fallbackId,
    ) ?? fallbackId
  );
}

// `forbidden`: a valid session whose account lacks the tracker scope.
type IdentityFailure = {
  ok: false;
  reason: string;
  detail?: string;
  forbidden?: boolean;
};

type IdentityResult =
  | { ok: true; userId: string; displayName: string }
  | IdentityFailure;

function logUnauthorizedRequest(
  request: FastifyRequest,
  route: string,
  failure: IdentityFailure,
): void {
  app.log.warn(
    {
      route,
      method: request.method,
      url: request.url,
      ip: request.ip,
      reason: failure.reason,
      detail: failure.detail,
    },
    "Rejected unauthorized request",
  );
}

/**
 * Answers a request that failed its identity check. A missing tracker scope
 * gets its own 403 so the app can tell "ask an admin for access" apart from
 * an expired or invalid session.
 */
function rejectRequest(
  request: FastifyRequest,
  reply: FastifyReply,
  route: string,
  failure: IdentityFailure,
) {
  logUnauthorizedRequest(request, route, failure);
  return failure.forbidden
    ? reply.code(403).send({ error: "Missing tracker scope" })
    : reply.code(401).send({ error: "Unauthorized" });
}

async function getCurrentUserIdentity(
  request: FastifyRequest,
): Promise<IdentityResult> {
  const authHeader = request.headers["authorization"];
  if (!authHeader) {
    return { ok: false, reason: "missing authorization header" };
  }
  if (!authHeader.startsWith("Bearer ")) {
    return { ok: false, reason: "authorization header is not a bearer token" };
  }
  const token = authHeader.slice(7).trim();
  if (!token) {
    return { ok: false, reason: "empty bearer token" };
  }

  try {
    const { payload } = await jwtVerify(token, JWKS, { algorithms: ["ES256"] });
    const sub =
      typeof payload.sub === "string" && payload.sub.length > 0
        ? payload.sub
        : null;
    if (!sub) {
      return { ok: false, reason: "token is missing a subject claim" };
    }
    if (!hasTrackerScope(payload)) {
      return {
        ok: false,
        reason: "account lacks the tracker scope",
        detail: `user ${sub}`,
        forbidden: true,
      };
    }

    return {
      ok: true,
      userId: sub,
      displayName: getDisplayNameFromToken(payload, sub),
    };
  } catch (error) {
    const reason =
      error instanceof joseErrors.JWTExpired
        ? "token expired"
        : error instanceof joseErrors.JWSSignatureVerificationFailed
          ? "token signature invalid"
          : "token verification failed";
    return {
      ok: false,
      reason,
      detail: error instanceof Error ? error.message : String(error),
    };
  }
}

type IngestIdentity =
  | { ok: true; userId: string; displayName: string; deviceId: string | null }
  | IdentityFailure;

/**
 * Identity for location ingest: the native tracking engine authenticates
 * with its long-lived device token (`Authorization: Device <token>`); older
 * clients and the app itself still use the user's JWT.
 */
async function getIngestIdentity(
  request: FastifyRequest,
): Promise<IngestIdentity> {
  const authHeader = request.headers["authorization"];
  if (typeof authHeader === "string" && authHeader.startsWith("Device ")) {
    const token = authHeader.slice(7).trim();
    if (!token) {
      return { ok: false, reason: "empty device token" };
    }
    const device = await deviceAuth.verify(token);
    if (!device) {
      return { ok: false, reason: "unknown or revoked device token" };
    }
    return {
      ok: true,
      userId: device.userId,
      displayName: lastKnownName.get(device.userId) ?? device.userName,
      deviceId: device.deviceId,
    };
  }

  const identity = await getCurrentUserIdentity(request);
  return identity.ok ? { ...identity, deviceId: null } : identity;
}

async function ensureBackendSchema(): Promise<void> {
  try {
    await pool.query(
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'user'",
    );
    await pool.query(
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS last_seen_at timestamptz",
    );
    await pool.query(
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS battery_level integer",
    );
    await pool.query(
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS is_charging boolean",
    );
    await pool.query(
      "ALTER TABLE location_history ADD COLUMN IF NOT EXISTS source text",
    );
    await pool.query(
      "ALTER TABLE location_history ADD COLUMN IF NOT EXISTS accuracy double precision",
    );
    await pool.query(
      `CREATE TABLE IF NOT EXISTS devices (
         id text PRIMARY KEY,
         user_id text NOT NULL REFERENCES users(id),
         token_hash text NOT NULL UNIQUE,
         platform text,
         created_at timestamptz NOT NULL DEFAULT now(),
         last_seen_at timestamptz,
         revoked_at timestamptz
       )`,
    );
    await pool.query(
      "CREATE INDEX IF NOT EXISTS devices_user_idx ON devices (user_id)",
    );
    await pool.query(
      `CREATE TABLE IF NOT EXISTS checkpoints (
         id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
         name text NOT NULL,
         location geography(Point, 4326) NOT NULL,
         radius_m integer NOT NULL CHECK (radius_m BETWEEN 10 AND 250),
         created_by text NOT NULL REFERENCES users(id),
         created_at timestamptz NOT NULL DEFAULT now(),
         updated_at timestamptz NOT NULL DEFAULT now()
       )`,
    );
    await pool.query(
      `CREATE UNIQUE INDEX IF NOT EXISTS checkpoints_name_uniq
       ON checkpoints (lower(btrim(name)))`,
    );
    await pool.query(
      `CREATE INDEX IF NOT EXISTS checkpoints_location_gist_idx
       ON checkpoints USING GIST (location)`,
    );
    await pool.query(
      `CREATE TABLE IF NOT EXISTS location_share_blocks (
         owner_id text NOT NULL REFERENCES users(id),
         viewer_id text NOT NULL REFERENCES users(id),
         created_at timestamptz NOT NULL DEFAULT now(),
         PRIMARY KEY (owner_id, viewer_id)
       )`,
    );
    await pool.query(
      `CREATE INDEX IF NOT EXISTS location_share_blocks_viewer_idx
       ON location_share_blocks (viewer_id)`,
    );
    // Collapse any pre-existing duplicate (user_id, recorded_at) rows first —
    // otherwise the unique index can't be built and every ON CONFLICT insert
    // below would then throw.
    await pool.query(
      `DELETE FROM location_history a
       USING location_history b
       WHERE a.user_id = b.user_id
         AND a.recorded_at = b.recorded_at
         AND a.id > b.id`,
    );
    await pool.query(
      `CREATE UNIQUE INDEX IF NOT EXISTS location_history_user_recorded_uniq
       ON location_history (user_id, recorded_at)`,
    );
  } catch (error) {
    app.log.warn({ error }, "Unable to ensure backend schema is present");
  }
}

function parseLocationItem(item: unknown): KnownLocation | null {
  if (item == null || typeof item !== "object") {
    return null;
  }

  const payload = item as LocationPayload;
  const coords = payload.coords;
  if (coords == null || typeof coords !== "object") {
    return null;
  }

  const latitude = normalizeNumber(coords.latitude);
  const longitude = normalizeNumber(coords.longitude);
  if (latitude == null || longitude == null) {
    return null;
  }

  const speed = normalizeNumber(coords.speed) ?? 0;
  const heading = normalizeNumber(coords.heading);
  const accuracyRaw = normalizeNumber(coords.accuracy);
  const accuracy =
    accuracyRaw !== null && accuracyRaw >= 0 ? accuracyRaw : null;
  const timestamp = payload.timestamp
    ? new Date(payload.timestamp)
    : new Date();
  if (Number.isNaN(timestamp.getTime())) {
    return null;
  }

  const batteryLevelRaw = normalizeNumber(payload.battery_level);
  const batteryLevel =
    batteryLevelRaw === null
      ? null
      : Math.max(0, Math.min(100, Math.round(batteryLevelRaw)));
  const isCharging =
    typeof payload.is_charging === "boolean" ? payload.is_charging : null;
  const source =
    typeof payload.source === "string" && payload.source.trim().length > 0
      ? payload.source.trim()
      : null;

  return {
    latitude,
    longitude,
    speed,
    heading: heading === null ? null : heading,
    accuracy,
    recordedAt: timestamp.toISOString(),
    batteryLevel,
    isCharging,
    source,
  };
}

async function ensureUserExists(
  userId: string,
  displayName: string,
): Promise<void> {
  await pool.query(
    `
      INSERT INTO users (id, name)
      VALUES ($1, $2)
      ON CONFLICT (id) DO UPDATE
      SET name = CASE
        WHEN users.name = users.id AND EXCLUDED.name IS DISTINCT FROM users.id
          THEN EXCLUDED.name
        ELSE users.name
      END
      WHERE users.name = users.id AND EXCLUDED.name IS DISTINCT FROM users.id
    `,
    [userId, displayName],
  );
}

async function insertLocationBatch(
  userId: string,
  points: KnownLocation[],
): Promise<void> {
  // Single multi-row insert — an offline drive can flush hundreds of points
  // at once and per-row round-trips add up. ON CONFLICT DO NOTHING against
  // (user_id, recorded_at) makes a re-flush after a partial failure a no-op.
  const rows = points.map((p) => ({
    recorded_at: p.recordedAt,
    lon: p.longitude,
    lat: p.latitude,
    speed: p.speed,
    heading: p.heading,
    accuracy: p.accuracy,
    source: p.source,
  }));
  await pool.query(
    `INSERT INTO location_history (user_id, recorded_at, location, speed, heading, accuracy, source)
     SELECT $1, r.recorded_at,
            ST_SetSRID(ST_MakePoint(r.lon, r.lat), 4326)::geography,
            r.speed, r.heading, r.accuracy, r.source
     FROM jsonb_to_recordset($2::jsonb)
       AS r(recorded_at timestamptz, lon float8, lat float8, speed float8,
             heading float8, accuracy float8, source text)
     ON CONFLICT (user_id, recorded_at) DO NOTHING`,
    [userId, JSON.stringify(rows)],
  );
}

async function touchLastSeen(
  userId: string,
  batteryLevel: number | null,
  isCharging: boolean | null,
): Promise<void> {
  try {
    await pool.query(
      `UPDATE users
       SET last_seen_at = now(),
           battery_level = COALESCE($2, battery_level),
           is_charging = COALESCE($3, is_charging)
       WHERE id = $1`,
      [userId, batteryLevel, isCharging],
    );
  } catch (error) {
    app.log.warn({ error, userId }, "Unable to update last_seen_at");
  }
}

async function getDwell(userId: string): Promise<Dwell | null> {
  if (dwellByUser.has(userId)) {
    return dwellByUser.get(userId) ?? null;
  }
  let dwell: Dwell | null = null;
  try {
    const result = await pool.query<DwellSeedRow>(DWELL_SEED_SQL, [
      userId,
      DWELL_MAX_SPEED,
      DWELL_RADIUS_METERS,
      [...TRIP_SOURCES],
    ]);
    dwell = result.rows[0] ? dwellFromSeedRow(result.rows[0]) : null;
  } catch (error) {
    app.log.warn({ error, userId }, "Unable to load the current stay");
    return null;
  }
  // A concurrent ingest may have started the stay in memory meanwhile.
  if (!dwellByUser.has(userId)) {
    dwellByUser.set(userId, dwell);
  }
  return dwellByUser.get(userId) ?? null;
}

function isSamePosition(
  latest: KnownLocation,
  previous: KnownLocation | undefined,
): boolean {
  return (
    previous != null &&
    previous.latitude === latest.latitude &&
    previous.longitude === latest.longitude
  );
}

/**
 * Stores and fans out a set of points from one user.
 *
 * `live` points (streamed only while someone watches) are broadcast but never
 * stored — the engine's recorded points already describe the path to within
 * a few metres. Batches can arrive out of order (an offline backlog after a
 * newer live point), so the broadcast only moves a viewer's marker forward in
 * time; anything else just refreshes presence (last seen + battery).
 */
async function ingestPoints(
  userId: string,
  displayName: string,
  points: KnownLocation[],
): Promise<{ stored: number }> {
  points.sort((a, b) => a.recordedAt.localeCompare(b.recordedAt));
  // Seed from history before this batch is stored, so the batch itself is
  // folded in exactly once below.
  let dwell = await getDwell(userId);
  for (const point of points) {
    dwell = advanceDwell(dwell, point);
  }
  dwellByUser.set(userId, dwell);
  const hereSince = dwell?.since ?? null;

  const stored = points.filter((p) => p.source !== "live");
  if (stored.length > 0) {
    await insertLocationBatch(userId, stored);
  }

  const newest = points[points.length - 1];
  await touchLastSeen(userId, newest.batteryLevel, newest.isCharging);

  const previous = lastKnownLocation.get(userId);
  const isNewer = previous == null || newest.recordedAt >= previous.recordedAt;
  if (isNewer) {
    lastKnownLocation.set(userId, newest);
  }

  const lastSeenAt = new Date().toISOString();
  const update =
    isNewer && !isSamePosition(newest, previous)
      ? {
          user_id: userId,
          username: displayName,
          latitude: newest.latitude,
          longitude: newest.longitude,
          speed: newest.speed,
          heading: newest.heading,
          recorded_at: newest.recordedAt,
          here_since: hereSince,
          battery_level: newest.batteryLevel,
          is_charging: newest.isCharging,
          last_seen_at: lastSeenAt,
        }
      : {
          user_id: userId,
          username: displayName,
          here_since: hereSince,
          battery_level: newest.batteryLevel,
          is_charging: newest.isCharging,
          last_seen_at: lastSeenAt,
        };
  // Viewers this user hides from get nothing: they already hold a redacted
  // entry and must learn nothing new, not even that the phone is active.
  connectionManager.broadcastEach(messageFor(sharing, userId, update));
  // After the broadcast, so a viewer waiting on a forced refresh already holds
  // the new position over the stream when its request completes.
  locationRefresh.noteUpload(userId);

  return { stored: stored.length };
}

/**
 * The roster as `viewerId` may see it. Every registered user is included
 * regardless of whether they've ever broadcast a location, so it is built
 * from the `users` table. Positions come from the newest of the in-memory
 * last-known point (includes unstored live points) and the latest stored
 * row — the latter keeps the map populated instantly after a restart,
 * even for users who are parked and therefore not sending anything. Users
 * not sharing with the viewer appear as redacted entries.
 */
async function buildSnapshot(viewerId: string, onlyUserId?: string) {
  const allUsers = await pool.query<{
    id: string;
    name: string;
    last_seen_at: Date | null;
    battery_level: number | null;
    is_charging: boolean | null;
    recorded_at: Date | null;
    latitude: number | null;
    longitude: number | null;
    speed: number | null;
    heading: number | null;
  }>(
    `SELECT u.id, u.name, u.last_seen_at, u.battery_level, u.is_charging,
            l.recorded_at, l.latitude, l.longitude, l.speed, l.heading
     FROM users u
     LEFT JOIN LATERAL (
       SELECT recorded_at,
              ST_Y(location::geometry) AS latitude,
              ST_X(location::geometry) AS longitude,
              speed, heading
       FROM location_history
       WHERE user_id = u.id
       ORDER BY recorded_at DESC
       LIMIT 1
     ) l ON true
     WHERE $1::text IS NULL OR u.id = $1`,
    [onlyUserId ?? null],
  );
  const visible = allUsers.rows.filter(
    (row) => !sharing.isHidden(row.id, viewerId),
  );
  const dwells = new Map(
    await Promise.all(
      visible.map(
        async (row) =>
          [row.id, row.recorded_at ? await getDwell(row.id) : null] as const,
      ),
    ),
  );
  return allUsers.rows.map((row) => {
    if (sharing.isHidden(row.id, viewerId)) {
      return redactedEntry(row.id, lastKnownName.get(row.id) ?? row.name);
    }
    const memory = lastKnownLocation.get(row.id);
    const storedAt = row.recorded_at
      ? new Date(row.recorded_at).toISOString()
      : null;
    const useMemory =
      memory != null && (storedAt == null || memory.recordedAt >= storedAt);
    return {
      user_id: row.id,
      username: lastKnownName.get(row.id) ?? row.name,
      sharing: true,
      latitude: useMemory ? memory.latitude : row.latitude,
      longitude: useMemory ? memory.longitude : row.longitude,
      speed: useMemory ? memory.speed : row.speed,
      heading: useMemory ? memory.heading : row.heading,
      recorded_at: useMemory ? memory.recordedAt : storedAt,
      here_since: dwells.get(row.id)?.since ?? null,
      battery_level: memory?.batteryLevel ?? row.battery_level,
      is_charging: memory?.isCharging ?? row.is_charging,
      last_seen_at: row.last_seen_at
        ? new Date(row.last_seen_at).toISOString()
        : null,
    };
  });
}

async function loadSharing(): Promise<void> {
  const { rows } = await pool.query<{ owner_id: string; viewer_id: string }>(
    "SELECT owner_id, viewer_id FROM location_share_blocks",
  );
  sharing.load(
    rows.map((r) => ({ ownerId: r.owner_id, viewerId: r.viewer_id })),
  );
}

app.get("/api/v1/sharing", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/sharing", identity);
  }
  return reply.send({ hidden_from: sharing.hiddenFrom(identity.userId) });
});

app.put("/api/v1/sharing/:viewerId", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/sharing/:viewerId", identity);
  }
  const { viewerId } = request.params as { viewerId: string };
  const enabled = (request.body as { enabled?: unknown } | null)?.enabled;
  if (typeof enabled !== "boolean") {
    return reply.code(400).send({ error: "`enabled` must be a boolean" });
  }
  if (viewerId === identity.userId) {
    return reply
      .code(400)
      .send({ error: "You can't change sharing with yourself" });
  }
  const { rows: known } = await pool.query(
    "SELECT 1 FROM users WHERE id = $1",
    [viewerId],
  );
  if (known.length === 0) {
    return reply.code(404).send({ error: "Unknown user" });
  }

  await ensureUserExists(identity.userId, identity.displayName);
  if (enabled) {
    await pool.query(
      "DELETE FROM location_share_blocks WHERE owner_id = $1 AND viewer_id = $2",
      [identity.userId, viewerId],
    );
  } else {
    await pool.query(
      `INSERT INTO location_share_blocks (owner_id, viewer_id)
       VALUES ($1, $2) ON CONFLICT DO NOTHING`,
      [identity.userId, viewerId],
    );
  }
  sharing.set(identity.userId, viewerId, enabled);

  // Tell the viewer right away: the marker disappears (or comes back with the
  // current position) without waiting for the next upload.
  const [entry] = await buildSnapshot(viewerId, identity.userId);
  if (entry) {
    connectionManager.sendTo(viewerId, entry);
  }
  app.log.info(
    { ownerId: identity.userId, viewerId, enabled },
    "[sharing] changed location sharing",
  );
  return reply.send({ hidden_from: sharing.hiddenFrom(identity.userId) });
});

// Wakes a user's phone for a fresh position and answers once it has reported
// in (200 with their roster entry) or the wait runs out (504).
app.post("/api/v1/users/:userId/location-refresh", async (request, reply) => {
  const route = "/api/v1/users/:userId/location-refresh";
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, route, identity);
  }
  const { userId } = request.params as { userId: string };
  const { rows: known } = await pool.query(
    "SELECT 1 FROM users WHERE id = $1",
    [userId],
  );
  if (known.length === 0) {
    return reply.code(404).send({ error: "Unknown user" });
  }
  if (sharing.isHidden(userId, identity.userId)) {
    return reply.code(403).send({ error: "not_sharing" });
  }
  const { rows: devices } = await pool.query(
    "SELECT 1 FROM user_fcm_tokens WHERE user_id = $1 LIMIT 1",
    [userId],
  );
  if (devices.length === 0) {
    return reply.code(409).send({ error: "no_device" });
  }

  const outcome = await locationRefresh.request(userId);
  app.log.info(
    { requesterId: identity.userId, userId, outcome },
    "[refresh] location refresh finished",
  );
  if (outcome === "timeout") {
    return reply.code(504).send({ error: "device_unreachable" });
  }
  const [entry] = await buildSnapshot(identity.userId, userId);
  return reply.send(entry);
});

app.get("/api/v1/profile", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/profile", identity);
  }

  await ensureUserExists(identity.userId, identity.displayName);

  const result = await pool.query(
    "SELECT id, name, avatar_url, role FROM users WHERE id = $1",
    [identity.userId],
  );

  if (result.rowCount === 0) {
    return reply.code(404).send({ error: "User not found" });
  }

  const user = result.rows[0];
  return reply.send({
    id: user.id,
    name: user.name,
    avatar_url: user.avatar_url ?? "",
    role: user.role ?? "user",
  });
});

app.patch("/api/v1/profile", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/profile", identity);
  }

  const body = request.body as Record<string, unknown> | null;
  if (body == null) {
    return reply.code(400).send({ error: "Missing profile payload" });
  }

  const name = typeof body.name === "string" ? body.name.trim() : null;
  const avatarUrl =
    typeof body.avatar_url === "string" ? body.avatar_url.trim() : null;

  if (name == null && avatarUrl == null) {
    return reply.code(400).send({ error: "Missing profile update fields" });
  }

  await ensureUserExists(identity.userId, identity.displayName);

  const updates = [] as string[];
  const params: Array<unknown> = [identity.userId];

  if (name != null) {
    updates.push(`name = $${params.length + 1}`);
    params.push(name);
  }
  if (avatarUrl != null) {
    updates.push(`avatar_url = $${params.length + 1}`);
    params.push(avatarUrl);
  }

  await pool.query(
    `UPDATE users SET ${updates.join(", ")} WHERE id = $1`,
    params,
  );

  const result = await pool.query(
    "SELECT id, name, avatar_url, role FROM users WHERE id = $1",
    [identity.userId],
  );

  const user = result.rows[0];
  return reply.send({
    id: user.id,
    name: user.name,
    avatar_url: user.avatar_url ?? "",
    role: user.role ?? "user",
  });
});

app.post("/api/v1/fcm-token", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/fcm-token", identity);
  }

  const body = request.body as Record<string, unknown> | null;
  const token = typeof body?.token === "string" ? body.token.trim() : null;
  if (!token) {
    return reply.code(400).send({ error: "Missing token" });
  }

  await ensureUserExists(identity.userId, identity.displayName);

  await pool.query(
    `INSERT INTO user_fcm_tokens (user_id, token, updated_at)
     VALUES ($1, $2, now())
     ON CONFLICT (user_id, token) DO UPDATE SET updated_at = now()`,
    [identity.userId, token],
  );

  return reply.send({ ok: true });
});

// Exchanges a valid user JWT for a long-lived device token the native
// tracking engine uploads with. `replaces` revokes the device's previous
// token (re-registration after reinstall / token loss).
app.post("/api/v1/devices", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/devices", identity);
  }

  const body = (request.body ?? {}) as Record<string, unknown>;
  const platform =
    typeof body.platform === "string" ? body.platform.slice(0, 32) : null;
  const replaces =
    typeof body.replaces === "string" && body.replaces.length > 0
      ? body.replaces
      : null;

  await ensureUserExists(identity.userId, identity.displayName);
  const { deviceId, token } = await deviceAuth.register(
    identity.userId,
    platform,
    replaces,
  );
  app.log.info(
    { userId: identity.userId, deviceId, platform },
    "[devices] registered device",
  );
  return reply.send({ device_id: deviceId, device_token: token });
});

app.delete("/api/v1/devices/:id", async (request, reply) => {
  const identity = await getIngestIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/devices/:id", identity);
  }

  const { id } = request.params as { id: string };
  // A device token may only revoke itself; a user JWT may revoke any of the
  // user's devices.
  if (identity.deviceId !== null && identity.deviceId !== id) {
    return reply.code(403).send({ error: "Forbidden" });
  }
  const revoked = await deviceAuth.revoke(id, identity.userId);
  return reply.send({ revoked });
});

// Checkpoints: shared named circles. Everyone with the tracker scope can
// list and create; only the creator or an admin can change or delete one.
const CHECKPOINT_COLUMNS = `
  id, name, radius_m, created_by, created_at, updated_at,
  ST_Y(location::geometry) AS latitude,
  ST_X(location::geometry) AS longitude`;

function checkpointResponse(row: Record<string, unknown>, canEdit: boolean) {
  return {
    id: row.id,
    name: row.name,
    latitude: row.latitude,
    longitude: row.longitude,
    radius_m: row.radius_m,
    created_by: row.created_by,
    created_at: row.created_at,
    updated_at: row.updated_at,
    can_edit: canEdit,
  };
}

async function getUserRole(userId: string): Promise<string> {
  const { rows } = await pool.query("SELECT role FROM users WHERE id = $1", [
    userId,
  ]);
  return (rows[0]?.role as string | undefined) ?? "user";
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    (error as { code?: unknown }).code === "23505"
  );
}

app.get("/api/v1/checkpoints", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/checkpoints", identity);
  }
  await ensureUserExists(identity.userId, identity.displayName);
  const role = await getUserRole(identity.userId);
  const { rows } = await pool.query(
    `SELECT ${CHECKPOINT_COLUMNS} FROM checkpoints ORDER BY lower(name)`,
  );
  return reply.send({
    checkpoints: rows.map((row) =>
      checkpointResponse(
        row,
        canModifyCheckpoint(role, row.created_by, identity.userId),
      ),
    ),
  });
});

app.post("/api/v1/checkpoints", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/checkpoints", identity);
  }
  const input = validateCheckpointInput(request.body);
  if (!input.ok) {
    return reply.code(400).send({ error: input.error });
  }
  const { name, latitude, longitude, radiusM } = input.value;

  await ensureUserExists(identity.userId, identity.displayName);
  try {
    const { rows } = await pool.query(
      `INSERT INTO checkpoints (name, location, radius_m, created_by)
       VALUES ($1, ST_SetSRID(ST_MakePoint($3, $2), 4326)::geography, $4, $5)
       RETURNING ${CHECKPOINT_COLUMNS}`,
      [name, latitude, longitude, radiusM, identity.userId],
    );
    return reply.code(201).send(checkpointResponse(rows[0], true));
  } catch (error) {
    if (isUniqueViolation(error)) {
      return reply.code(409).send({ error: "Checkpoint name already exists" });
    }
    throw error;
  }
});

app.patch("/api/v1/checkpoints/:id", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/checkpoints/:id", identity);
  }
  const { id } = request.params as { id: string };
  const input = validateCheckpointInput(request.body);
  if (!input.ok) {
    return reply.code(400).send({ error: input.error });
  }
  const { name, latitude, longitude, radiusM } = input.value;

  await ensureUserExists(identity.userId, identity.displayName);
  const role = await getUserRole(identity.userId);
  try {
    // Ownership is checked in the UPDATE itself so a concurrent delete or
    // reassignment can't slip between a read and the write.
    const { rows } = await pool.query(
      `UPDATE checkpoints
       SET name = $2,
           location = ST_SetSRID(ST_MakePoint($4, $3), 4326)::geography,
           radius_m = $5,
           updated_at = now()
       WHERE id = $1 AND ($6 OR created_by = $7)
       RETURNING ${CHECKPOINT_COLUMNS}`,
      [id, name, latitude, longitude, radiusM, role === "admin", identity.userId],
    );
    if (rows.length > 0) {
      return reply.send(checkpointResponse(rows[0], true));
    }
  } catch (error) {
    if (isUniqueViolation(error)) {
      return reply.code(409).send({ error: "Checkpoint name already exists" });
    }
    if ((error as { code?: unknown }).code === "22P02") {
      // Not a valid uuid.
      return reply.code(404).send({ error: "Checkpoint not found" });
    }
    throw error;
  }
  const exists = await pool.query("SELECT 1 FROM checkpoints WHERE id = $1", [
    id,
  ]);
  return exists.rowCount
    ? reply.code(403).send({ error: "Forbidden" })
    : reply.code(404).send({ error: "Checkpoint not found" });
});

app.delete("/api/v1/checkpoints/:id", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/checkpoints/:id", identity);
  }
  const { id } = request.params as { id: string };

  await ensureUserExists(identity.userId, identity.displayName);
  const role = await getUserRole(identity.userId);
  try {
    const deleted = await pool.query(
      "DELETE FROM checkpoints WHERE id = $1 AND ($2 OR created_by = $3)",
      [id, role === "admin", identity.userId],
    );
    if (deleted.rowCount) {
      return reply.send({ deleted: true });
    }
  } catch (error) {
    if ((error as { code?: unknown }).code === "22P02") {
      return reply.code(404).send({ error: "Checkpoint not found" });
    }
    throw error;
  }
  const exists = await pool.query("SELECT 1 FROM checkpoints WHERE id = $1", [
    id,
  ]);
  return exists.rowCount
    ? reply.code(403).send({ error: "Forbidden" })
    : reply.code(404).send({ error: "Checkpoint not found" });
});

// Public, like the GitHub releases behind it: the app also checks for
// updates before anyone has signed in.
app.get("/api/v1/app/android/latest", async (_request, reply) => {
  if (!androidReleases) {
    return reply.code(204).send();
  }
  try {
    const release = await androidReleases.latest();
    if (!release) {
      return reply.code(204).send();
    }
    return reply.send({
      version_code: release.versionCode,
      version_name: release.versionName,
      apk_url: release.apkUrl,
      sha256: release.sha256,
      size: release.size,
      notes: release.notes,
      published_at: release.publishedAt,
    });
  } catch (error) {
    app.log.warn({ error }, "[updates] unable to read Android releases");
    return reply.code(503).send({ error: "Release information unavailable" });
  }
});

app.post("/api/v1/streams/ticket", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/streams/ticket", identity);
  }

  const ticket = crypto.randomUUID();
  lastKnownName.set(identity.userId, identity.displayName);
  tickets.set(ticket, {
    userId: identity.userId,
    displayName: identity.displayName,
    expiresAt: Date.now() + 60_000,
    used: false,
  });

  await ensureUserExists(identity.userId, identity.displayName);
  app.log.info(
    { userId: identity.userId, displayName: identity.displayName },
    "[ws] issued websocket ticket",
  );

  return reply.send({ ticket });
});

app.post("/api/v1/location", async (request, reply) => {
  const identity = await getIngestIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/location", identity);
  }

  const body = request.body;
  const items = Array.isArray(body) ? body : [body];
  const points = items
    .map(parseLocationItem)
    .filter((point): point is KnownLocation => point !== null);
  if (points.length === 0) {
    return reply.code(400).send({ error: "Invalid location payload" });
  }

  if (identity.deviceId === null) {
    await ensureUserExists(identity.userId, identity.displayName);
    lastKnownName.set(identity.userId, identity.displayName);
  } else {
    await deviceAuth.touch(identity.deviceId);
  }

  const { stored } = await ingestPoints(
    identity.userId,
    identity.displayName,
    points,
  );
  const latest = points[points.length - 1];
  app.log.info(
    {
      userId: identity.userId,
      deviceId: identity.deviceId,
      pointCount: points.length,
      stored,
      source: latest.source,
      recordedAt: latest.recordedAt,
    },
    "[location] ingested location batch",
  );

  const pacingMode = getPacingMode();
  reply.header("X-Pacing-Mode", pacingMode);

  // `live_ttl_s` piggybacks the live state on every upload, so a device that
  // missed the push still converges within one upload.
  return reply.send({
    received: points.length,
    stored,
    pacing: pacingMode,
    live_ttl_s: liveController.ttlSeconds,
  });
});

app.get("/api/v1/history", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/history", identity);
  }

  const query = request.query as Record<string, string | undefined>;
  const userId =
    query.user_id && query.user_id.trim().length > 0
      ? query.user_id.trim()
      : identity.userId;

  if (sharing.isHidden(userId, identity.userId)) {
    return reply.code(403).send({ error: "not_sharing" });
  }

  const to = query.to ? new Date(query.to) : new Date();
  const from = query.from
    ? new Date(query.from)
    : new Date(to.getTime() - DEFAULT_HISTORY_WINDOW_MS);

  if (Number.isNaN(from.getTime()) || Number.isNaN(to.getTime())) {
    return reply.code(400).send({ error: "Invalid from/to timestamp" });
  }
  if (to.getTime() < from.getTime()) {
    return reply.code(400).send({ error: "`to` must be after `from`" });
  }

  // `points=false`: session summaries only (start/end/stats), for the
  // history calendar.
  const includePoints = query.points !== "false" && query.points !== "0";
  const maxWindowMs = includePoints
    ? MAX_HISTORY_WINDOW_MS
    : MAX_SUMMARY_WINDOW_MS;
  const clampedFrom = new Date(
    Math.max(from.getTime(), to.getTime() - maxWindowMs),
  );

  const result = await pool.query(
    `SELECT recorded_at,
            ST_Y(location::geometry) AS latitude,
            ST_X(location::geometry) AS longitude,
            speed, heading, accuracy, source
     FROM location_history
     WHERE user_id = $1 AND recorded_at >= $2 AND recorded_at <= $3
     ORDER BY recorded_at ASC`,
    [userId, clampedFrom.toISOString(), to.toISOString()],
  );

  const points: HistoryPoint[] = result.rows.map((row) => ({
    recordedAt: new Date(row.recorded_at).toISOString(),
    latitude: Number(row.latitude),
    longitude: Number(row.longitude),
    speed: Number(row.speed),
    heading: row.heading === null ? null : Number(row.heading),
    accuracy: row.accuracy === null ? null : Number(row.accuracy),
    source: row.source ?? null,
  }));

  const sessions = buildSessions(points);
  app.log.info(
    {
      userId,
      requestedBy: identity.userId,
      pointCount: points.length,
      sessionCount: sessions.length,
      includePoints,
      from: clampedFrom.toISOString(),
      to: to.toISOString(),
    },
    "[history] served location history",
  );

  return reply.send({
    user_id: userId,
    from: clampedFrom.toISOString(),
    to: to.toISOString(),
    sessions: sessions.map((session) => ({
      start_at: session.startAt,
      end_at: session.endAt,
      duration_seconds: session.durationSeconds,
      distance_meters: session.distanceMeters,
      avg_speed: session.avgSpeed,
      top_speed: session.topSpeed,
      point_count: session.pointCount,
      points: includePoints
        ? session.points.map((point) => ({
            latitude: point.latitude,
            longitude: point.longitude,
            speed: point.speed,
            heading: point.heading,
            accuracy: point.accuracy ?? null,
            recorded_at: point.recordedAt,
          }))
        : undefined,
    })),
  });
});

// Deletes the caller's own stored points between `from` and `to` (both
// inclusive): one trip is its start..end window, a day is the whole day. There
// is deliberately no `user_id` — nobody can erase someone else's history — and
// no device-token access: it takes a signed-in user.
app.delete("/api/v1/history", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/history", identity);
  }

  const range = parseHistoryRange(
    request.query as Record<string, string | undefined>,
    MAX_HISTORY_WINDOW_MS,
  );
  if (!range.ok) {
    return reply.code(400).send({ error: range.error });
  }

  const result = await pool.query(
    `DELETE FROM location_history
     WHERE user_id = $1 AND recorded_at >= $2 AND recorded_at <= $3`,
    [identity.userId, range.from.toISOString(), range.to.toISOString()],
  );
  // The cached current stay was derived from the points just removed.
  dwellByUser.delete(identity.userId);

  app.log.info(
    {
      userId: identity.userId,
      deleted: result.rowCount,
      from: range.from.toISOString(),
      to: range.to.toISOString(),
    },
    "[history] deleted location history",
  );
  return reply.send({ deleted: result.rowCount ?? 0 });
});

// @fastify/websocket adds its `onRoute` hook only once the plugin finishes
// loading during boot. Routes declared at the top level are registered *before*
// that hook exists, so `{ websocket: true }` is silently ignored and the handler
// runs as a plain HTTP route — receiving (request, reply) instead of a websocket
// connection. That is why `connection.socket.close()` / `connection.destroy()`
// blew up. Registering inside app.register() defers this route until after the
// plugin has loaded, so it is correctly upgraded.
app.register(async () => {
  app.get("/api/v1/stream", { websocket: true }, async (connection, req) => {
    const urlParams = new URLSearchParams((req.url ?? "").split("?")[1] ?? "");
    const ticket = urlParams.get("ticket") ?? "";
    const entry = tickets.get(ticket);

    if (!entry || entry.used || entry.expiresAt < Date.now()) {
      const reason = !entry
        ? "unknown ticket"
        : entry.used
          ? "ticket already used"
          : "ticket expired";
      app.log.warn(
        {
          reason,
          ticketPresent: ticket.length > 0,
          remoteAddress: req.socket.remoteAddress,
        },
        "[ws] rejected websocket upgrade",
      );
      try {
        connection.socket.close(1008, "Unauthorized");
      } catch {
        connection.destroy();
      }
      return;
    }

    entry.used = true;
    tickets.delete(ticket);
    const userId = entry.userId;
    const displayName = entry.displayName;
    lastKnownName.set(userId, displayName);
    connectionManager.add(userId, connection.socket);
    app.log.info(
      { userId, totalConnections: connectionManager.count },
      "[ws] client connected",
    );
    updateViewerState();

    // Listen before the snapshot query: clients announce their map state as
    // soon as the socket opens, and anything sent while nobody listens is lost.
    connection.socket.on("pong", () => {
      connectionManager.markAlive(userId, connection.socket);
    });

    connection.socket.on("message", async (raw: Buffer | string) => {
      const rawStr = raw.toString();
      app.log.info({ userId, data: rawStr }, "[ws] message received");

      let msg: unknown;
      try {
        msg = JSON.parse(rawStr);
      } catch {
        app.log.warn({ userId, data: rawStr }, "[ws] failed to parse message");
        return;
      }

      if (typeof msg !== "object" || msg === null) {
        return;
      }

      const msgType = (msg as Record<string, unknown>)["type"];

      if (msgType === "map_active") {
        const active = (msg as Record<string, unknown>)["active"];
        if (typeof active !== "boolean") {
          return;
        }
        connectionManager.setMapActive(userId, connection.socket, active);
        void updateViewerState();
        return;
      }

      if (msgType !== "location") {
        return;
      }

      // Legacy path: builds before the native tracking engine streamed
      // foreground fixes over the socket. Current builds upload over HTTP.
      const point = parseLocationItem(msg);
      if (!point) {
        app.log.warn({ userId, msg }, "[ws] invalid location payload");
        return;
      }

      await ingestPoints(userId, displayName, [point]);
    });

    connection.socket.on("close", () => {
      app.log.info(
        { userId, totalConnections: connectionManager.count - 1 },
        "[ws] client disconnected",
      );
      connectionManager.remove(userId, connection.socket);
      updateViewerState();
    });

    const snapshot = await buildSnapshot(userId);
    app.log.info(
      { userId, userCount: snapshot.length },
      "[ws] sending snapshot",
    );
    connection.socket.send(
      JSON.stringify({ type: "snapshot", users: snapshot }),
    );
    connection.socket.send(JSON.stringify(viewersMessage()));
  });
});

const port = Number(process.env.PORT || 3000);

const start = async (): Promise<void> => {
  try {
    initializeFcm();
    await ensureBackendSchema();
    await loadSharing();
    await app.listen({ port, host: "0.0.0.0" });
    app.log.info(`Legacy Tracker server listening on http://0.0.0.0:${port}`);
    setInterval(() => {
      if (connectionManager.sweep() > 0) void updateViewerState();
    }, HEARTBEAT_INTERVAL_MS).unref();
    if (androidReleases) {
      void announceNewAndroidRelease();
      setInterval(() => void announceNewAndroidRelease(), RELEASE_CHECK_INTERVAL_MS).unref();
    }
  } catch (error) {
    app.log.error(error);
    process.exit(1);
  }
};

start();
