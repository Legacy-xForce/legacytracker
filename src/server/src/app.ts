import 'dotenv/config';
import crypto from 'crypto';
import Fastify, { FastifyRequest } from 'fastify';
import cors from '@fastify/cors';
import websocket from '@fastify/websocket';
import pool from './config/db';
import ConnectionManager from './services/connection-manager';

const app = Fastify({ logger: true });
const connectionManager = new ConnectionManager();
const tickets = new Map<string, TicketEntry>();
const lastKnownLocation = new Map<string, KnownLocation>();
const STATE_ID = 'foreground';

const PacingMode = {
  AGGRESSIVE: 'AGGRESSIVE',
  PASSIVE: 'PASSIVE',
} as const;

type PacingMode = (typeof PacingMode)[keyof typeof PacingMode];

interface TicketEntry {
  userId: string;
  expiresAt: number;
  used: boolean;
}

interface KnownLocation {
  latitude: number;
  longitude: number;
  speed: number;
  heading: number | null;
  recordedAt: string;
}

interface LocationPayload {
  coords?: {
    latitude?: number;
    longitude?: number;
    speed?: number;
    heading?: number;
  };
  timestamp?: string;
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
}

function normalizeNumber(value: unknown): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return null;
  }
  return value;
}

function getUserIdFromRequest(request: FastifyRequest): string | null {
  const userId = String(request.headers['x-user-id'] || '').trim();
  return userId.length > 0 ? userId : null;
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

  return {
    latitude,
    longitude,
    speed,
    heading: heading === null ? null : heading,
    recordedAt: timestamp.toISOString(),
  };
}

async function ensureUserExists(userId: string): Promise<void> {
  await pool.query(
    'INSERT INTO users (id, name) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING',
    [userId, userId],
  );

  await pool.query(
    `INSERT INTO notifications (user_id, content)
     SELECT $1, 'Welcome to Legacy Tracker. Manage your notifications from the profile page.'
     WHERE NOT EXISTS (SELECT 1 FROM notifications WHERE user_id = $1)`,
    [userId],
  );
}

app.get('/api/v1/profile', async (request, reply) => {
  const userId = getUserIdFromRequest(request);
  if (!userId) {
    return reply.code(401).send({ error: 'Missing X-User-Id header' });
  }

  await ensureUserExists(userId);

  const result = await pool.query(
    'SELECT id, name, avatar_url, role FROM users WHERE id = $1',
    [userId],
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
  const userId = getUserIdFromRequest(request);
  if (!userId) {
    return reply.code(401).send({ error: 'Missing X-User-Id header' });
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

  await ensureUserExists(userId);

  const updates = [] as string[];
  const params: Array<unknown> = [userId];

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
    [userId],
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
  const userId = getUserIdFromRequest(request);
  if (!userId) {
    return reply.code(401).send({ error: 'Missing X-User-Id header' });
  }

  await ensureUserExists(userId);

  const result = await pool.query(
    'SELECT id, content, read, created_at FROM notifications WHERE user_id = $1 ORDER BY created_at DESC',
    [userId],
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
  const userId = getUserIdFromRequest(request);
  if (!userId) {
    return reply.code(401).send({ error: 'Missing X-User-Id header' });
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
    [notificationId, userId],
  );

  return reply.send({ success: true });
});

app.post('/api/v1/streams/ticket', async (request, reply) => {
  const userId = getUserIdFromRequest(request);
  if (!userId) {
    return reply.code(401).send({ error: 'Missing X-User-Id header' });
  }

  const ticket = crypto.randomUUID();
  tickets.set(ticket, {
    userId,
    expiresAt: Date.now() + 60_000,
    used: false,
  });

  await ensureUserExists(userId);

  return reply.send({ ticket });
});

app.post('/api/v1/location', async (request, reply) => {
  const userId = String(request.headers['x-user-id'] || '').trim();
  if (!userId) {
    return reply.code(401).send({ error: 'Missing X-User-Id header' });
  }

  const body = request.body;
  const items = Array.isArray(body) ? body : [body];
  const points = items.map(parseLocationItem).filter((point): point is KnownLocation => point !== null);
  if (points.length === 0) {
    return reply.code(400).send({ error: 'Invalid location payload' });
  }

  await ensureUserExists(userId);

  for (const point of points) {
    await pool.query(
      `INSERT INTO location_history (user_id, recorded_at, location, speed, heading)
       VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography, $5, $6)`,
      [userId, point.recordedAt, point.longitude, point.latitude, point.speed, point.heading],
    );
  }

  const latest = points[points.length - 1];
  lastKnownLocation.set(userId, latest);

  const broadcastMessage = {
    user_id: userId,
    latitude: latest.latitude,
    longitude: latest.longitude,
    speed: latest.speed,
    heading: latest.heading,
    recorded_at: latest.recordedAt,
  };
  connectionManager.broadcast(broadcastMessage);

  const pacingMode = getPacingMode();
  reply.header('X-Pacing-Mode', pacingMode);

  return reply.send({ received: points.length, pacing: pacingMode });
});

app.get('/api/v1/stream', { websocket: true }, (connection, req) => {
  const query = req.query as Record<string, unknown>;
  const ticket = String(query.ticket || '').trim();
  const entry = tickets.get(ticket);

  if (!entry || entry.used || entry.expiresAt < Date.now()) {
    connection.socket.close(1008, 'Unauthorized');
    return;
  }

  entry.used = true;
  tickets.delete(ticket);
  const userId = entry.userId;
  connectionManager.add(userId, connection.socket);
  updateViewerState();

  if (lastKnownLocation.size > 0) {
    const snapshot = Array.from(lastKnownLocation.entries()).map(([id, point]) => ({
      user_id: id,
      latitude: point.latitude,
      longitude: point.longitude,
      speed: point.speed,
      heading: point.heading,
      recorded_at: point.recordedAt,
    }));
    connection.socket.send(JSON.stringify({ type: 'snapshot', users: snapshot }));
  }

  connection.socket.on('close', () => {
    connectionManager.remove(userId);
    updateViewerState();
  });
});

const port = Number(process.env.PORT || 3000);

const start = async (): Promise<void> => {
  try {
    await ensureBackendSchema();
    await app.listen({ port, host: '0.0.0.0' });
    app.log.info(`Legacy Tracker server listening on http://0.0.0.0:${port}`);
  } catch (error) {
    app.log.error(error);
    process.exit(1);
  }
};

start();
