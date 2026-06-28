import 'dotenv/config';
import crypto from 'crypto';
import Fastify, { FastifyRequest } from 'fastify';
import cors from '@fastify/cors';
import websocket from '@fastify/websocket';
import { createRemoteJWKSet, jwtVerify, type JWTPayload } from 'jose';
import pool from './config/db';
import ConnectionManager from './services/connection-manager';
import { initializeFcm, broadcastPacingMode } from './services/fcm-service';

const JWKS = createRemoteJWKSet(new URL('https://auth.legacy-group.tech/.well-known/jwks.json'), {
  timeoutDuration: 5000,
});

const app = Fastify({ logger: true });
const connectionManager = new ConnectionManager();
const tickets = new Map<string, TicketEntry>();
const lastKnownLocation = new Map<string, KnownLocation>();
const lastKnownName = new Map<string, string>();
const STATE_ID = 'foreground';

const PacingMode = {
  AGGRESSIVE: 'AGGRESSIVE',
  PASSIVE: 'PASSIVE',
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
  recordedAt: string;
  batteryLevel: number | null;
  isCharging: boolean | null;
}

interface LocationPayload {
  coords?: {
    latitude?: number;
    longitude?: number;
    speed?: number;
    heading?: number;
  };
  timestamp?: string;
  battery_level?: number;
  is_charging?: boolean;
}

app.register(cors, {
  origin: true,
  methods: ['GET', 'POST'],
});
app.register(websocket);

function getPacingMode(): PacingMode {
  return connectionManager.count > 0 ? PacingMode.AGGRESSIVE : PacingMode.PASSIVE;
}

async function updateViewerState(): Promise<void> {
  try {
    await pool.query(
      `INSERT INTO viewer_state (id, active_viewers)
       VALUES ($1, $2)
       ON CONFLICT (id)
       DO UPDATE SET active_viewers = EXCLUDED.active_viewers, updated_at = now()`,
      [STATE_ID, connectionManager.count],
    );
  } catch (error) {
    app.log.warn({ error }, 'Unable to synchronize viewer state with database');
  }

  // Push new pacing mode to all registered devices via FCM.
  try {
    const result = await pool.query<{ token: string }>('SELECT token FROM user_fcm_tokens');
    const tokens = result.rows.map((r) => r.token);
    await broadcastPacingMode(tokens, getPacingMode());
  } catch (error) {
    app.log.warn({ error }, 'Unable to broadcast pacing mode via FCM');
  }
}

function normalizeNumber(value: unknown): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return null;
  }
  return value;
}

function readStringClaim(payload: JWTPayload, claim: string): string | null {
  const value = payload[claim];
  if (typeof value !== 'string') {
    return null;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function getDisplayNameFromToken(payload: JWTPayload, fallbackId: string): string {
  const candidates = [
    readStringClaim(payload, 'preferred_username'),
    readStringClaim(payload, 'username'),
    readStringClaim(payload, 'nickname'),
    readStringClaim(payload, 'name'),
    readStringClaim(payload, 'email'),
  ];

  return candidates.find((candidate) => candidate != null && candidate !== fallbackId) ?? fallbackId;
}

async function getCurrentUserIdentity(request: FastifyRequest): Promise<{ userId: string; displayName: string } | null> {
  const authHeader = request.headers['authorization'] ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  if (!token) return null;

  try {
    const { payload } = await jwtVerify(token, JWKS, { algorithms: ['ES256'] });
    const sub = typeof payload.sub === 'string' && payload.sub.length > 0 ? payload.sub : null;
    if (!sub) {
      return null;
    }

    return {
      userId: sub,
      displayName: getDisplayNameFromToken(payload, sub),
    };
  } catch {
    return null;
  }
}

async function ensureBackendSchema(): Promise<void> {
  try {
    await pool.query("ALTER TABLE users ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'user'");
    await pool.query(`
      CREATE TABLE IF NOT EXISTS notifications (
        id bigserial PRIMARY KEY,
        user_id text NOT NULL REFERENCES users(id),
        content text NOT NULL,
        read boolean NOT NULL DEFAULT false,
        created_at timestamptz NOT NULL DEFAULT now()
      )`,
    );
  } catch (error) {
    app.log.warn({ error }, 'Unable to ensure backend schema is present');
  }
}

function parseLocationItem(item: unknown): KnownLocation | null {
  if (item == null || typeof item !== 'object') {
    return null;
  }

  const payload = item as LocationPayload;
  const coords = payload.coords;
  if (coords == null || typeof coords !== 'object') {
    return null;
  }

  const latitude = normalizeNumber(coords.latitude);
  const longitude = normalizeNumber(coords.longitude);
  if (latitude == null || longitude == null) {
    return null;
  }

  const speed = normalizeNumber(coords.speed) ?? 0;
  const heading = normalizeNumber(coords.heading);
  const timestamp = payload.timestamp ? new Date(payload.timestamp) : new Date();
  if (Number.isNaN(timestamp.getTime())) {
    return null;
  }

  const batteryLevelRaw = normalizeNumber(payload.battery_level);
  const batteryLevel =
    batteryLevelRaw === null ? null : Math.max(0, Math.min(100, Math.round(batteryLevelRaw)));
  const isCharging = typeof payload.is_charging === 'boolean' ? payload.is_charging : null;

  return {
    latitude,
    longitude,
    speed,
    heading: heading === null ? null : heading,
    recordedAt: timestamp.toISOString(),
    batteryLevel,
    isCharging,
  };
}

async function ensureUserExists(userId: string, displayName: string): Promise<void> {
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

  await pool.query(
    `INSERT INTO notifications (user_id, content)
     SELECT $1, 'Welcome to Legacy Tracker. Manage your notifications from the profile page.'
     WHERE NOT EXISTS (SELECT 1 FROM notifications WHERE user_id = $1)`,
    [userId],
  );
}

app.get('/api/v1/profile', async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity) {
    return reply.code(401).send({ error: 'Unauthorized' });
  }

  await ensureUserExists(identity.userId, identity.displayName);

  const result = await pool.query(
    'SELECT id, name, avatar_url, role FROM users WHERE id = $1',
    [identity.userId],
  );

  if (result.rowCount === 0) {
    return reply.code(404).send({ error: 'User not found' });
  }

  const user = result.rows[0];
  return reply.send({
    id: user.id,
    name: user.name,
    avatar_url: user.avatar_url ?? '',
    role: user.role ?? 'user',
  });
});

app.patch('/api/v1/profile', async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity) {
    return reply.code(401).send({ error: 'Unauthorized' });
  }

  const body = request.body as Record<string, unknown> | null;
  if (body == null) {
    return reply.code(400).send({ error: 'Missing profile payload' });
  }

  const name = typeof body.name === 'string' ? body.name.trim() : null;
  const avatarUrl = typeof body.avatar_url === 'string' ? body.avatar_url.trim() : null;

  if (name == null && avatarUrl == null) {
    return reply.code(400).send({ error: 'Missing profile update fields' });
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

  await pool.query(`UPDATE users SET ${updates.join(', ')} WHERE id = $1`, params);

  const result = await pool.query(
    'SELECT id, name, avatar_url, role FROM users WHERE id = $1',
    [identity.userId],
  );

  const user = result.rows[0];
  return reply.send({
    id: user.id,
    name: user.name,
    avatar_url: user.avatar_url ?? '',
    role: user.role ?? 'user',
  });
});

app.get('/api/v1/notifications', async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity) {
    return reply.code(401).send({ error: 'Unauthorized' });
  }

  await ensureUserExists(identity.userId, identity.displayName);

  const result = await pool.query(
    'SELECT id, content, read, created_at FROM notifications WHERE user_id = $1 ORDER BY created_at DESC',
    [identity.userId],
  );

  return reply.send({
    notifications: result.rows.map((notification) => ({
      'id': notification.id,
      'content': notification.content,
      'read': notification.read,
      'created_at': notification.created_at,
    })),
  });
});

app.post('/api/v1/notifications/read', async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity) {
    return reply.code(401).send({ error: 'Unauthorized' });
  }

  const body = request.body as Record<string, unknown> | null;
  if (body == null || body.notification_id == null) {
    return reply.code(400).send({ error: 'Missing notification_id' });
  }

  const notificationId = Number(body.notification_id);
  if (!Number.isInteger(notificationId) || notificationId <= 0) {
    return reply.code(400).send({ error: 'Invalid notification_id' });
  }

  await pool.query(
    'UPDATE notifications SET read = true WHERE id = $1 AND user_id = $2',
    [notificationId, identity.userId],
  );

  return reply.send({ success: true });
});

app.post('/api/v1/fcm-token', async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity) {
    return reply.code(401).send({ error: 'Unauthorized' });
  }

  const body = request.body as Record<string, unknown> | null;
  const token = typeof body?.token === 'string' ? body.token.trim() : null;
  if (!token) {
    return reply.code(400).send({ error: 'Missing token' });
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

app.post('/api/v1/streams/ticket', async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity) {
    return reply.code(401).send({ error: 'Unauthorized' });
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

  return reply.send({ ticket });
});

app.post('/api/v1/location', async (request, reply) => {
  const identity = await getCurrentUserIdentity(request);
  if (!identity) {
    return reply.code(401).send({ error: 'Unauthorized' });
  }

  const body = request.body;
  const items = Array.isArray(body) ? body : [body];
  const points = items.map(parseLocationItem).filter((point): point is KnownLocation => point !== null);
  if (points.length === 0) {
    return reply.code(400).send({ error: 'Invalid location payload' });
  }

  await ensureUserExists(identity.userId, identity.displayName);
  lastKnownName.set(identity.userId, identity.displayName);

  for (const point of points) {
    await pool.query(
      `INSERT INTO location_history (user_id, recorded_at, location, speed, heading)
       VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography, $5, $6)`,
      [identity.userId, point.recordedAt, point.longitude, point.latitude, point.speed, point.heading],
    );
  }

  const latest = points[points.length - 1];
  lastKnownLocation.set(identity.userId, latest);

  const broadcastMessage = {
    user_id: identity.userId,
    username: identity.displayName,
    latitude: latest.latitude,
    longitude: latest.longitude,
    speed: latest.speed,
    heading: latest.heading,
    recorded_at: latest.recordedAt,
    battery_level: latest.batteryLevel,
    is_charging: latest.isCharging,
  };
  connectionManager.broadcast(broadcastMessage);

  const pacingMode = getPacingMode();
  reply.header('X-Pacing-Mode', pacingMode);

  return reply.send({ received: points.length, pacing: pacingMode });
});

// @fastify/websocket adds its `onRoute` hook only once the plugin finishes
// loading during boot. Routes declared at the top level are registered *before*
// that hook exists, so `{ websocket: true }` is silently ignored and the handler
// runs as a plain HTTP route — receiving (request, reply) instead of a websocket
// connection. That is why `connection.socket.close()` / `connection.destroy()`
// blew up. Registering inside app.register() defers this route until after the
// plugin has loaded, so it is correctly upgraded.
app.register(async () => {
  app.get('/api/v1/stream', { websocket: true }, (connection, req) => {
  const urlParams = new URLSearchParams((req.url ?? '').split('?')[1] ?? '');
  const ticket = urlParams.get('ticket') ?? '';
  const entry = tickets.get(ticket);

  if (!entry || entry.used || entry.expiresAt < Date.now()) {
    try {
      connection.socket.close(1008, 'Unauthorized');
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
  app.log.info({ userId, totalConnections: connectionManager.count }, '[ws] client connected');
  updateViewerState();

  if (lastKnownLocation.size > 0) {
    const snapshot = Array.from(lastKnownLocation.entries()).map(([id, point]) => ({
      user_id: id,
      username: lastKnownName.get(id) ?? id,
      latitude: point.latitude,
      longitude: point.longitude,
      speed: point.speed,
      heading: point.heading,
      recorded_at: point.recordedAt,
      battery_level: point.batteryLevel,
      is_charging: point.isCharging,
    }));
    app.log.info({ userId, userCount: snapshot.length }, '[ws] sending snapshot');
    connection.socket.send(JSON.stringify({ type: 'snapshot', users: snapshot }));
  }

  connection.socket.on('message', async (raw: Buffer | string) => {
    const rawStr = raw.toString();
    app.log.info({ userId, data: rawStr }, '[ws] message received');

    let msg: unknown;
    try {
      msg = JSON.parse(rawStr);
    } catch {
      app.log.warn({ userId, data: rawStr }, '[ws] failed to parse message');
      return;
    }

    if (typeof msg !== 'object' || msg === null || (msg as Record<string, unknown>)['type'] !== 'location') {
      return;
    }

    const point = parseLocationItem(msg);
    if (!point) {
      app.log.warn({ userId, msg }, '[ws] invalid location payload');
      return;
    }

    await pool.query(
      `INSERT INTO location_history (user_id, recorded_at, location, speed, heading)
       VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography, $5, $6)`,
      [userId, point.recordedAt, point.longitude, point.latitude, point.speed, point.heading],
    );

    lastKnownLocation.set(userId, point);

    const broadcast = {
      user_id: userId,
      username: displayName,
      latitude: point.latitude,
      longitude: point.longitude,
      speed: point.speed,
      heading: point.heading,
      recorded_at: point.recordedAt,
      battery_level: point.batteryLevel,
      is_charging: point.isCharging,
    };
    app.log.info({ broadcast, recipients: connectionManager.count }, '[ws] broadcasting location');
    connectionManager.broadcast(broadcast);
  });

  connection.socket.on('close', () => {
    app.log.info({ userId, totalConnections: connectionManager.count - 1 }, '[ws] client disconnected');
    connectionManager.remove(userId);
    updateViewerState();
  });
  });
});

const port = Number(process.env.PORT || 3000);

const start = async (): Promise<void> => {
  try {
    initializeFcm();
    await ensureBackendSchema();
    await app.listen({ port, host: '0.0.0.0' });
    app.log.info(`Legacy Tracker server listening on http://0.0.0.0:${port}`);
  } catch (error) {
    app.log.error(error);
    process.exit(1);
  }
};

start();
