import 'dotenv/config';
import crypto from 'crypto';
import Fastify from 'fastify';
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
}

app.post('/api/v1/streams/ticket', async (request, reply) => {
  const userId = String(request.headers['x-user-id'] || '').trim();
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
    await app.listen({ port, host: '0.0.0.0' });
    app.log.info(`Legacy Tracker server listening on http://0.0.0.0:${port}`);
  } catch (error) {
    app.log.error(error);
    process.exit(1);
  }
};

start();
