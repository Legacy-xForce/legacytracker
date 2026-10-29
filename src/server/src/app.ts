import "dotenv/config";
import crypto from "crypto";
import Fastify, { FastifyReply, FastifyRequest } from "fastify";
import cors from "@fastify/cors";
import websocket from "@fastify/websocket";
import { createRemoteJWKSet } from "jose";
import pool from "./config/db";
import {
  ApiTokenLimitError,
  ApiTokens,
  ipMatchesAllowlist,
  isAllowedForScope,
  isApiTokenId,
  parseAllowedIps,
  validateApiTokenInput,
} from "./services/api-tokens";
import {
  ApiTokenRequests,
  DEFAULT_API_TOKEN_REQUEST_LIMIT,
  MAX_API_TOKEN_REQUEST_LIMIT,
  requestPath,
  userAgentOf,
} from "./services/api-token-requests";
import { AndroidReleaseSource } from "./services/app-releases";
import {
  canModifyCheckpoint,
  validateCheckpointInput,
} from "./services/checkpoints";
import {
  CLOUDFLARE_CIDRS,
  clientAddressOf,
} from "./services/client-address";
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
import {
  MapboxNotConfiguredError,
  MapboxTokenRequestError,
  MapboxTokenService,
} from "./services/mapbox-tokens";
import { ViewerPresence } from "./services/viewer-presence";
import { parseHistoryRange } from "./services/history-range";
import {
  rankLeaderboard,
  summarizeTravel,
  type TravelTotals,
} from "./services/leaderboard";
import { buildSessions, type HistoryPoint } from "./services/session-builder";
import {
  messageFor,
  redactedEntry,
  SharingRegistry,
} from "./services/sharing";
import {
  verifyAccessToken,
  verifyLogoutToken,
  type LogoutTokenResult,
} from "./services/access-token";
import { getDisplayNameFromToken } from "./services/display-name";
import {
  parseTrackingIssues,
  type TrackingIssue,
} from "./services/tracking-issues";

// Legacy Auth, which signs the access tokens this server accepts. Point both
// at a staging auth service to run against it.
const AUTH_JWKS_URI =
  process.env.AUTH_JWKS_URI ??
  "https://auth.legacy-group.tech/.well-known/jwks.json";
const AUTH_ISSUER = process.env.AUTH_ISSUER ?? "https://auth.legacy-group.tech";

const JWKS = createRemoteJWKSet(new URL(AUTH_JWKS_URI), {
  timeoutDuration: 5000,
});

// OIDC clients whose tokens are accepted: the web app and the phone app.
const AUTH_ALLOWED_CLIENTS = (
  process.env.AUTH_ALLOWED_CLIENTS ?? "tracker-spa,tracker-mobile"
)
  .split(",")
  .map((client) => client.trim())
  .filter((client) => client.length > 0);
// Android builds older than this must update before they can be used.
const ANDROID_MIN_SUPPORTED_CODE = Number(process.env.ANDROID_MIN_SUPPORTED_CODE ?? 0) || 0;
// The only client that may register devices (mint device tokens) and ask for
// Mapbox temporary tokens. The web uses a URL-restricted public token instead.
const AUTH_MOBILE_CLIENT = process.env.AUTH_MOBILE_CLIENT ?? "tracker-mobile";

const authVerifier = {
  jwks: JWKS,
  issuer: AUTH_ISSUER,
  allowedClients: AUTH_ALLOWED_CLIENTS,
};

// Browser origins allowed to call the API. Unset, any origin is reflected,
// which is only safe while credentials travel in headers rather than cookies.
const CORS_ALLOWED_ORIGINS = (process.env.CORS_ALLOWED_ORIGINS ?? "")
  .split(",")
  .map((origin) => origin.trim())
  .filter((origin) => origin.length > 0);

// Addresses we believe when a proxy reports where the client connected from.
// Production is Cloudflare -> Traefik -> this container, so the CDN's edge
// ranges and the private networks an in-network proxy reaches us from are
// listed. `request.ip` then walks `X-Forwarded-For` from our own socket peer
// leftwards and stops at the first address not on this list. Trusting
// addresses rather than a hop count is what makes a forged chain fail: the
// proxy always appends the caller's real address as the last hop, so spoofed
// entries to its left are never reached. `trustProxy: true` would take the
// leftmost entry instead, which the caller controls outright.
// See services/client-address.ts for the address API tokens are checked
// against, which goes one step further and names the visitor behind Cloudflare.
const TRUSTED_PROXY_CIDRS = (
  process.env.TRUSTED_PROXY_CIDRS ??
  ["loopback", "uniquelocal", ...CLOUDFLARE_CIDRS].join(",")
)
  .split(",")
  .map((cidr) => cidr.trim())
  .filter((cidr) => cidr.length > 0);

const app = Fastify({
  trustProxy: TRUSTED_PROXY_CIDRS,
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
const apiTokens = new ApiTokens(pool);
const apiTokenRequests = new ApiTokenRequests(pool);
// The phone app has no Mapbox token of its own: it asks this server for a
// short-lived one. The secret below can mint tokens and must stay server-side.
const mapboxTokens = new MapboxTokenService({
  secretToken: process.env.MAPBOX_SECRET_TOKEN,
  username: process.env.MAPBOX_USERNAME,
  ttlSeconds: Number(process.env.MAPBOX_TOKEN_TTL_SECONDS),
});
if (!mapboxTokens.configured) {
  app.log.warn(
    "[mapbox] MAPBOX_SECRET_TOKEN and MAPBOX_USERNAME are not set; the app cannot get a map token",
  );
}
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
// The travel leaderboard rebuilds everyone's trips for its window, so a
// year is as far as one request goes.
const MAX_LEADERBOARD_WINDOW_MS = 366 * 24 * 60 * 60 * 1000;

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
  // Issued to a read-only caller: the stream may watch, not upload.
  readOnly: boolean;
  // OP session of the token the ticket was issued for: a back-channel logout
  // for it closes the stream.
  sid: string | null;
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
  /** Settings blocking updates, as the device reported them; null if it didn't say. */
  trackingIssues: TrackingIssue[] | null;
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
  tracking_issues?: unknown;
}

// The web client calls from its own origin: every method a route uses must be
// listed, or the browser blocks the request (PUT /api/v1/sharing/:viewerId).
app.register(cors, {
  origin: CORS_ALLOWED_ORIGINS.length > 0 ? CORS_ALLOWED_ORIGINS : true,
  methods: ["GET", "POST", "PUT", "PATCH", "DELETE"],
});
if (CORS_ALLOWED_ORIGINS.length === 0) {
  app.log.warn("[cors] CORS_ALLOWED_ORIGINS not set — any web origin may call this API");
}
app.register(websocket);

interface ApiTokenRequestContext {
  tokenId: string;
  userId: string;
  clientIp: string;
}

// The request itself is the key, so no Fastify decoration (and no leaking of
// one request's token into another) is involved.
const apiTokenRequestContexts = new WeakMap<
  FastifyRequest,
  ApiTokenRequestContext
>();

// `onResponse` is the first point at which the final status is known, and it
// runs after the reply has been sent: a slow insert can't delay the caller.
app.addHook("onResponse", async (request, reply) => {
  const context = apiTokenRequestContexts.get(request);
  if (!context) {
    return;
  }
  try {
    await apiTokenRequests.record({
      tokenId: context.tokenId,
      userId: context.userId,
      method: request.method,
      path: requestPath(request.url),
      statusCode: reply.statusCode,
      clientIp: context.clientIp,
      userAgent: userAgentOf(request.headers["user-agent"]),
      durationMs: Math.max(0, Math.round(reply.elapsedTime)),
    });
  } catch (error) {
    // Logging a request must never break the request itself.
    app.log.warn(
      { error, tokenId: context.tokenId },
      "[api-tokens] unable to record request",
    );
  }
});

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

// `forbidden`: a valid credential that may not do this — an account without
// the tracker scope, or an API token outside its scope. `error` replaces the
// default 403 message.
type IdentityFailure = {
  ok: false;
  reason: string;
  detail?: string;
  forbidden?: boolean;
  error?: string;
};

// `readOnly` callers (read API tokens, `tracker.read` sessions) can't write.
// `clientId` is the OIDC client of a session token (null for API tokens and
// legacy password-login tokens) and `sid` its OP session.
type IdentityResult =
  | {
      ok: true;
      userId: string;
      displayName: string;
      readOnly: boolean;
      clientId: string | null;
      sid: string | null;
    }
  | IdentityFailure;

type IdentityOptions = {
  // Routes that mint credentials or manage tokens: a leaked API token must
  // not be able to issue itself replacements.
  sessionOnly?: boolean;
};

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
    ? reply.code(403).send({ error: failure.error ?? "Missing tracker scope" })
    : reply.code(401).send({ error: "Unauthorized" });
}

function readApiTokenHeader(request: FastifyRequest): string | null {
  const header = request.headers["x-api-token"];
  const value = Array.isArray(header) ? header[0] : header;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

/**
 * The address an API token is allowed or denied on. `request.ip` stops at the
 * proxy in front of us, which behind Cloudflare is one of their addresses for
 * everyone; see services/client-address.ts for what makes it the visitor.
 */
function apiClientAddress(request: FastifyRequest): string {
  const forwarded = request.headers["x-forwarded-for"];
  const connecting =
    request.headers["cf-connecting-ip"] ?? request.headers["cf-client-ip"];
  return (
    clientAddressOf({
      forwardedFor: Array.isArray(forwarded) ? forwarded.join(",") : forwarded,
      connectingIp: Array.isArray(connecting) ? connecting[0] : connecting,
      socketAddress: request.socket.remoteAddress,
    }) ?? request.ip
  );
}

/**
 * Identity from a personal API token (`X-API-Token`). It acts as its owner,
 * so every route behaves as it would for their session, but a read token is
 * turned away from anything that changes data, and a token limited to certain
 * source addresses is turned away from anywhere else.
 */
async function getApiTokenIdentity(
  request: FastifyRequest,
  token: string,
  options: IdentityOptions,
): Promise<IdentityResult> {
  const identity = await apiTokens.authenticate(token);
  const clientAddress = apiClientAddress(request);
  if (identity) {
    // Whatever the outcome, the request is part of this token's history.
    apiTokenRequestContexts.set(request, {
      tokenId: identity.tokenId,
      userId: identity.userId,
      clientIp: clientAddress,
    });
  }
  if (options.sessionOnly) {
    return {
      ok: false,
      reason: "API token used on a session-only route",
      forbidden: true,
      error: "API tokens can't be used here; sign in instead",
    };
  }
  if (!identity) {
    return { ok: false, reason: "unknown or revoked API token" };
  }
  if (!ipMatchesAllowlist(clientAddress, identity.allowedIps)) {
    // The rejected address travels in the log line, because it is the one the
    // owner has to add to lift the block.
    return {
      ok: false,
      reason: "api token used outside its address allowlist",
      detail: `token ${identity.tokenId} from ${clientAddress}`,
      forbidden: true,
      error: "This API token is not allowed from your address",
    };
  }
  if (
    !isAllowedForScope(
      identity.scope,
      request.method,
      request.routeOptions.url ?? "",
    )
  ) {
    return {
      ok: false,
      reason: "read-only API token used for a write",
      detail: `token ${identity.tokenId}`,
      forbidden: true,
      error: "This API token is read-only",
    };
  }
  return {
    ok: true,
    userId: identity.userId,
    displayName: lastKnownName.get(identity.userId) ?? identity.userName,
    readOnly: identity.scope === "read",
    clientId: null,
    sid: null,
  };
}

async function getCurrentUserIdentity(
  request: FastifyRequest,
  options: IdentityOptions = {},
): Promise<IdentityResult> {
  const apiToken = readApiTokenHeader(request);
  if (apiToken) {
    return getApiTokenIdentity(request, apiToken, options);
  }

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

  const verified = await verifyAccessToken(token, authVerifier);
  if (!verified.ok) {
    if (verified.lostTrackerScope && verified.sub) {
      // The account lost access: its API tokens go with it.
      purgeApiTokens(verified.sub, "a token without the tracker scope");
    }
    return verified;
  }
  if (
    !isAllowedForScope(
      verified.scope,
      request.method,
      request.routeOptions.url ?? "",
    )
  ) {
    return {
      ok: false,
      reason: "read-only token used for a write",
      detail: `user ${verified.sub}`,
      forbidden: true,
      error: "This session is read-only",
    };
  }
  return {
    ok: true,
    userId: verified.sub,
    displayName: getDisplayNameFromToken(verified.payload, verified.sub),
    readOnly: verified.scope === "read",
    clientId: verified.clientId,
    sid: verified.sid,
  };
}

function purgeApiTokens(userId: string, cause: string): void {
  void apiTokens
    .removeAllForUser(userId)
    .then((removed) => {
      if (removed > 0) {
        app.log.info(
          { userId, removed },
          `[api-tokens] removed tokens after ${cause}`,
        );
      }
    })
    .catch((error) => {
      app.log.warn({ error }, "[api-tokens] unable to remove tokens");
    });
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

/**
 * Brings the schema up to date before the server listens. A failure is
 * rethrown so `start()` can exit: the container must never become healthy
 * with a half-migrated database and turn every request into a 500.
 */
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
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS tracking_issues text[] NOT NULL DEFAULT '{}'",
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
    await pool.query(
      `CREATE TABLE IF NOT EXISTS api_tokens (
         id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
         user_id text NOT NULL REFERENCES users(id),
         name text NOT NULL,
         scope text NOT NULL CHECK (scope IN ('read', 'write')),
         token_hash text NOT NULL UNIQUE,
         token_hint text NOT NULL,
         created_at timestamptz NOT NULL DEFAULT now(),
         last_used_at timestamptz,
         rotated_at timestamptz
       )`,
    );
    await pool.query(
      "CREATE INDEX IF NOT EXISTS api_tokens_user_idx ON api_tokens (user_id)",
    );
    await pool.query(
      "ALTER TABLE api_tokens ADD COLUMN IF NOT EXISTS allowed_ips text[] NOT NULL DEFAULT '{}'",
    );
    await pool.query(
      "ALTER TABLE api_tokens ADD COLUMN IF NOT EXISTS deleted boolean NOT NULL DEFAULT false",
    );
    await pool.query(
      `CREATE TABLE IF NOT EXISTS api_token_requests (
         id bigserial PRIMARY KEY,
         token_id uuid NOT NULL REFERENCES api_tokens(id) ON DELETE CASCADE,
         user_id text NOT NULL,
         method text NOT NULL,
         path text NOT NULL,
         status_code integer NOT NULL,
         client_ip text,
         user_agent text,
         duration_ms integer,
         created_at timestamptz NOT NULL DEFAULT now()
       )`,
    );
    await pool.query(
      `CREATE INDEX IF NOT EXISTS api_token_requests_token_id_idx
       ON api_token_requests (token_id, id DESC)`,
    );
    await pool.query(
      `CREATE INDEX IF NOT EXISTS api_token_requests_user_created_idx
       ON api_token_requests (user_id, created_at DESC)`,
    );
    // Earlier builds created this reference as ON DELETE SET NULL. Existing
    // databases are not rebuilt by CREATE TABLE IF NOT EXISTS, so move them to
    // the cascade the soft-delete model expects (only when it still differs).
    await pool.query(
      `DO $$
       BEGIN
         IF EXISTS (
           SELECT 1 FROM pg_constraint
           WHERE conrelid = 'api_token_requests'::regclass
             AND conname = 'api_token_requests_token_id_fkey'
             AND confdeltype <> 'c'
         ) THEN
           ALTER TABLE api_token_requests
             DROP CONSTRAINT api_token_requests_token_id_fkey;
           ALTER TABLE api_token_requests
             ADD CONSTRAINT api_token_requests_token_id_fkey
             FOREIGN KEY (token_id) REFERENCES api_tokens(id) ON DELETE CASCADE;
         END IF;
       END $$`,
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
    app.log.error({ error }, "Unable to ensure backend schema is present");
    throw error;
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
    trackingIssues: parseTrackingIssues(payload.tracking_issues),
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
  trackingIssues: TrackingIssue[] | null,
): Promise<void> {
  try {
    await pool.query(
      `UPDATE users
       SET last_seen_at = now(),
           battery_level = COALESCE($2, battery_level),
           is_charging = COALESCE($3, is_charging),
           tracking_issues = COALESCE($4::text[], tracking_issues)
       WHERE id = $1`,
      [userId, batteryLevel, isCharging, trackingIssues],
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
  // The device attaches its current settings to one point of the upload;
  // points are sorted, so the last one that carries them is the freshest.
  let trackingIssues: TrackingIssue[] | null = null;
  for (const point of points) {
    if (point.trackingIssues !== null) trackingIssues = point.trackingIssues;
  }
  await touchLastSeen(
    userId,
    newest.batteryLevel,
    newest.isCharging,
    trackingIssues,
  );

  const previous = lastKnownLocation.get(userId);
  const isNewer = previous == null || newest.recordedAt >= previous.recordedAt;
  if (isNewer) {
    lastKnownLocation.set(userId, newest);
  }

  const lastSeenAt = new Date().toISOString();
  // Only when the device reported them: a missing field means "unchanged".
  const issues = trackingIssues === null ? {} : { tracking_issues: trackingIssues };
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
          ...issues,
        }
      : {
          user_id: userId,
          username: displayName,
          here_since: hereSince,
          battery_level: newest.batteryLevel,
          is_charging: newest.isCharging,
          last_seen_at: lastSeenAt,
          ...issues,
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
    tracking_issues: string[] | null;
    recorded_at: Date | null;
    latitude: number | null;
    longitude: number | null;
    speed: number | null;
    heading: number | null;
  }>(
    `SELECT u.id, u.name, u.last_seen_at, u.battery_level, u.is_charging,
            u.tracking_issues, l.recorded_at, l.latitude, l.longitude, l.speed, l.heading
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
      tracking_issues: row.tracking_issues ?? [],
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
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
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

// Mints a short-lived Mapbox token for the phone app. Release builds carry no
// Mapbox token, so they fetch one here before creating the map. Tokens are
// cached per user until shortly before they expire. Only the app's sessions
// may ask: the web ships a public token restricted to its own origins.
app.post("/api/v1/mapbox/token", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/mapbox/token", identity);
  }
  if (identity.clientId !== null && identity.clientId !== AUTH_MOBILE_CLIENT) {
    return rejectRequest(request, reply, "/api/v1/mapbox/token", {
      ok: false,
      reason: "Mapbox token requested by a client other than the app",
      detail: `client_id ${identity.clientId}`,
      forbidden: true,
      error: "Map tokens are only issued to the app",
    });
  }

  try {
    const token = await mapboxTokens.getForUser(identity.userId);
    // A bearer credential: never let a proxy or browser cache it.
    return reply.header("Cache-Control", "no-store").send({
      token: token.token,
      expires_at: token.expiresAt,
    });
  } catch (error) {
    if (error instanceof MapboxNotConfiguredError) {
      app.log.error(
        { userId: identity.userId },
        "[mapbox] token requested but the service is not configured",
      );
      return reply.code(503).send({ error: "Map rendering is not configured" });
    }
    if (error instanceof MapboxTokenRequestError) {
      // The message is safe to log: it never contains the secret or a token.
      app.log.error(
        { userId: identity.userId, status: error.status, error: error.message },
        "[mapbox] unable to mint a temporary token",
      );
      return reply.code(503).send({ error: "Map rendering is temporarily unavailable" });
    }
    throw error;
  }
});

// Exchanges a valid user JWT for a long-lived device token the native
// tracking engine uploads with. `replaces` revokes the device's previous
// token (re-registration after reinstall / token loss). Only the phone app's
// sessions may do this: a token taken from the web app can't mint devices.
app.post("/api/v1/devices", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/devices", identity);
  }
  if (identity.clientId !== null && identity.clientId !== AUTH_MOBILE_CLIENT) {
    return rejectRequest(request, reply, "/api/v1/devices", {
      ok: false,
      reason: "device registration from a client other than the app",
      detail: `client_id ${identity.clientId}`,
      forbidden: true,
      error: "Devices can only be registered from the app",
    });
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

// Personal API tokens. Managed only from a signed-in session; see
// services/api-tokens.ts for how they authenticate.
app.get("/api/v1/api-tokens", async (request, reply) => {
  const route = "/api/v1/api-tokens";
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
  if (!identity.ok) {
    return rejectRequest(request, reply, route, identity);
  }
  return reply.send({
    tokens: await apiTokens.list(identity.userId),
    // Lets the dialog offer the address it is answering from instead of
    // making the owner guess it: that is how an allowlist mistake stops being
    // a lockout.
    your_ip: apiClientAddress(request),
  });
});

// Everyone can see every token on the tracker: the metadata is non-secret and
// reviewing what can read or write is the point. Managing them stays with the
// owner, and the trail each one leaves is readable through the requests route.
app.get("/api/v1/api-tokens/all", async (request, reply) => {
  const route = "/api/v1/api-tokens/all";
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
  if (!identity.ok) {
    return rejectRequest(request, reply, route, identity);
  }
  return reply.send({ tokens: await apiTokens.listAll() });
});

app.post("/api/v1/api-tokens", async (request, reply) => {
  const route = "/api/v1/api-tokens";
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
  if (!identity.ok) {
    return rejectRequest(request, reply, route, identity);
  }
  const input = validateApiTokenInput(request.body);
  if (!input.ok) {
    return reply.code(400).send({ error: input.error });
  }

  await ensureUserExists(identity.userId, identity.displayName);
  try {
    const issued = await apiTokens.create(
      identity.userId,
      input.value.name,
      input.value.scope,
    );
    app.log.info(
      { userId: identity.userId, tokenId: issued.id, scope: issued.scope },
      "[api-tokens] created token",
    );
    return reply.code(201).send(issued);
  } catch (error) {
    if (error instanceof ApiTokenLimitError) {
      return reply.code(400).send({ error: error.message });
    }
    throw error;
  }
});

app.post("/api/v1/api-tokens/:id/rotate", async (request, reply) => {
  const route = "/api/v1/api-tokens/:id/rotate";
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
  if (!identity.ok) {
    return rejectRequest(request, reply, route, identity);
  }
  const { id } = request.params as { id: string };
  const issued = isApiTokenId(id)
    ? await apiTokens.rotate(identity.userId, id)
    : null;
  if (!issued) {
    return reply.code(404).send({ error: "API token not found" });
  }
  app.log.info(
    { userId: identity.userId, tokenId: id },
    "[api-tokens] rotated token",
  );
  return reply.send(issued);
});

app.patch("/api/v1/api-tokens/:id", async (request, reply) => {
  const route = "/api/v1/api-tokens/:id";
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
  if (!identity.ok) {
    return rejectRequest(request, reply, route, identity);
  }
  const input = parseAllowedIps(
    (request.body as { allowed_ips?: unknown } | null)?.allowed_ips,
  );
  if (!input.ok) {
    return reply.code(400).send({ error: input.error });
  }
  const { id } = request.params as { id: string };
  const updated = isApiTokenId(id)
    ? await apiTokens.updateAllowedIps(identity.userId, id, input.value)
    : null;
  if (!updated) {
    return reply.code(404).send({ error: "API token not found" });
  }
  app.log.info(
    { userId: identity.userId, tokenId: id, allowedIps: updated.allowed_ips },
    "[api-tokens] changed allowed addresses",
  );
  return reply.send(updated);
});

app.delete("/api/v1/api-tokens/:id", async (request, reply) => {
  const route = "/api/v1/api-tokens/:id";
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
  if (!identity.ok) {
    return rejectRequest(request, reply, route, identity);
  }
  const { id } = request.params as { id: string };
  const removed = isApiTokenId(id)
    ? await apiTokens.remove(identity.userId, id)
    : false;
  if (!removed) {
    return reply.code(404).send({ error: "API token not found" });
  }
  app.log.info(
    { userId: identity.userId, tokenId: id },
    "[api-tokens] deleted token",
  );
  return reply.send({ deleted: true });
});

// The token's audit trail, readable by any signed-in session: transparency
// about what integrations do is the point. Still session-only, so a leaked
// token can't read or scrub what other tokens did.
app.get("/api/v1/api-tokens/:id/requests", async (request, reply) => {
  const route = "/api/v1/api-tokens/:id/requests";
  const identity = await getCurrentUserIdentity(request, { sessionOnly: true });
  if (!identity.ok) {
    return rejectRequest(request, reply, route, identity);
  }
  const { id } = request.params as { id: string };
  if (!isApiTokenId(id)) {
    return reply.code(404).send({ error: "API token not found" });
  }
  const query = request.query as Record<string, unknown>;
  const rawLimit = typeof query.limit === "string" ? query.limit : "";
  const requested = /^\d+$/.test(rawLimit)
    ? Number(rawLimit)
    : DEFAULT_API_TOKEN_REQUEST_LIMIT;
  const limit = Math.min(
    Math.max(requested, 1),
    MAX_API_TOKEN_REQUEST_LIMIT,
  );
  const rawBefore = typeof query.before === "string" ? query.before : null;
  if (rawBefore !== null && !/^\d+$/.test(rawBefore)) {
    return reply.code(400).send({ error: "`before` must be a request id" });
  }
  const page = await apiTokenRequests.listForToken(id, {
    limit,
    before: rawBefore,
  });
  if (!page) {
    return reply.code(404).send({ error: "API token not found" });
  }
  return reply.send(page);
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
      // Builds below this are blocked until they update (e.g. once the
      // password login they rely on is gone).
      min_supported_code: ANDROID_MIN_SUPPORTED_CODE,
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
    readOnly: identity.readOnly,
    sid: identity.sid,
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

// Who travelled furthest between `from` and `to`, with each person's moving
// time and speeds. Built from the same trips as the history, so GPS drift
// while parked doesn't count. People who hide their location from the caller
// are left out entirely: distance alone says when they were on the move.
app.get("/api/v1/leaderboard", async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity.ok) {
    return rejectRequest(request, reply, "/api/v1/leaderboard", identity);
  }

  const range = parseHistoryRange(
    request.query as Record<string, string | undefined>,
    MAX_LEADERBOARD_WINDOW_MS,
  );
  if (!range.ok) {
    return reply.code(400).send({ error: range.error });
  }

  const users = await pool.query<{ id: string; name: string }>(
    "SELECT id, name FROM users",
  );
  const totals: { userId: string; name: string; totals: TravelTotals }[] = [];
  // One person at a time keeps a long window from holding everyone's points
  // in memory at once.
  for (const user of users.rows) {
    if (sharing.isHidden(user.id, identity.userId)) continue;
    const result = await pool.query(
      `SELECT recorded_at,
              ST_Y(location::geometry) AS latitude,
              ST_X(location::geometry) AS longitude,
              speed, source
       FROM location_history
       WHERE user_id = $1 AND recorded_at >= $2 AND recorded_at <= $3
         AND source IS DISTINCT FROM 'heartbeat' AND source IS DISTINCT FROM 'ping'
       ORDER BY recorded_at ASC`,
      [user.id, range.from.toISOString(), range.to.toISOString()],
    );
    const points: HistoryPoint[] = result.rows.map((row) => ({
      recordedAt: new Date(row.recorded_at).toISOString(),
      latitude: Number(row.latitude),
      longitude: Number(row.longitude),
      speed: Number(row.speed),
      heading: null,
      source: row.source ?? null,
    }));
    totals.push({
      userId: user.id,
      name: lastKnownName.get(user.id) ?? user.name,
      totals: summarizeTravel(points),
    });
  }

  const entries = rankLeaderboard(totals, identity.userId);
  app.log.info(
    {
      requestedBy: identity.userId,
      entries: entries.length,
      from: range.from.toISOString(),
      to: range.to.toISOString(),
    },
    "[leaderboard] served travel leaderboard",
  );

  return reply.send({
    from: range.from.toISOString(),
    to: range.to.toISOString(),
    entries: entries.map((entry) => ({
      user_id: entry.userId,
      username: entry.name,
      rank: entry.rank,
      distance_meters: entry.distanceMeters,
      duration_seconds: entry.durationSeconds,
      avg_speed: entry.avgSpeed,
      top_speed: entry.topSpeed,
      trip_count: entry.tripCount,
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

// OpenID Connect back-channel logout: Legacy Auth posts a logout token here
// when a session of the web or phone app ends at the OP (sign-out elsewhere,
// lost access, disabled account). Open streams of that session are told to
// sign out; lost access also deletes the user's API tokens.
app.addContentTypeParser(
  "application/x-www-form-urlencoded",
  { parseAs: "string" },
  (_request, body, done) => {
    done(null, Object.fromEntries(new URLSearchParams(body as string)));
  },
);

app.post("/auth/backchannel-logout", async (request, reply) => {
  const body = (request.body ?? {}) as Record<string, unknown>;
  const logoutToken =
    typeof body.logout_token === "string" ? body.logout_token : "";
  const verified: LogoutTokenResult = logoutToken
    ? await verifyLogoutToken(logoutToken, authVerifier)
    : { ok: false, reason: "missing logout_token" };
  reply.header("Cache-Control", "no-store");
  if (!verified.ok) {
    app.log.warn(
      { reason: verified.reason, detail: verified.detail, ip: request.ip },
      "[auth] rejected back-channel logout",
    );
    return reply.code(400).send({ error: "invalid_request" });
  }

  const message = { type: "signed_out" };
  let closed = 0;
  if (verified.accessRevoked && verified.sub) {
    purgeApiTokens(verified.sub, "the account lost access");
    closed = connectionManager.closeUser(verified.sub, message);
  } else if (verified.sid) {
    closed = connectionManager.closeSession(verified.sid, message);
  } else if (verified.sub) {
    closed = connectionManager.closeUser(verified.sub, message, {
      sessionsOnly: true,
    });
  }
  app.log.info(
    {
      userId: verified.sub,
      sid: verified.sid,
      accessRevoked: verified.accessRevoked,
      closed,
    },
    "[auth] back-channel logout",
  );
  return reply.code(200).send();
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
    const readOnly = entry.readOnly;
    lastKnownName.set(userId, displayName);
    connectionManager.add(userId, connection.socket, entry.sid);
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

      if (msgType !== "location" || readOnly) {
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

// Lightweight liveness probe for Docker/Coolify. It answers as soon as the
// HTTP server is accepting requests; startup work (schema, FCM, sharing) has
// already completed by the time we listen.
app.get("/health", async (_request, reply) => {
  return reply.code(200).send({ status: "ok" });
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
