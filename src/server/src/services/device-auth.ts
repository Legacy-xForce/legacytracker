import crypto from "crypto";
import type { Pool } from "pg";

export interface DeviceIdentity {
  deviceId: string;
  userId: string;
  userName: string;
}

interface CacheEntry {
  identity: DeviceIdentity | null;
  expiresAt: number;
}

// Live mode uploads a point every few seconds per device; caching keeps that
// from costing a DB round-trip each. Unknown tokens are cached briefly so a
// revoked device that keeps retrying doesn't hammer the table either.
const CACHE_TTL_MS = 5 * 60_000;
const NEGATIVE_CACHE_TTL_MS = 30_000;
const TOUCH_INTERVAL_MS = 5 * 60_000;

export function hashDeviceToken(token: string): string {
  return crypto.createHash("sha256").update(token, "utf8").digest("hex");
}

/**
 * Long-lived, revocable upload credentials for the native tracking engine.
 *
 * The engine uploads while the app is closed — possibly for days — so it
 * can't rely on the short-lived JWT, and refreshing a rotating refresh token
 * from both the engine and the Dart auth layer would race. Instead the app
 * exchanges a valid JWT for a device token once, and the engine presents it
 * as `Authorization: Device <token>`. Only sha256(token) is persisted.
 */
export class DeviceAuth {
  private readonly cache = new Map<string, CacheEntry>();
  private readonly lastTouch = new Map<string, number>();

  constructor(private readonly pool: Pool) {}

  async register(
    userId: string,
    platform: string | null,
    replacesDeviceId: string | null,
  ): Promise<{ deviceId: string; token: string }> {
    const token = crypto.randomBytes(32).toString("base64url");
    const deviceId = crypto.randomUUID();
    await this.pool.query(
      `INSERT INTO devices (id, user_id, token_hash, platform)
       VALUES ($1, $2, $3, $4)`,
      [deviceId, userId, hashDeviceToken(token), platform],
    );
    if (replacesDeviceId) {
      await this.revoke(replacesDeviceId, userId);
    }
    return { deviceId, token };
  }

  async revoke(deviceId: string, userId: string): Promise<boolean> {
    const result = await this.pool.query<{ token_hash: string }>(
      `UPDATE devices SET revoked_at = now()
       WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
       RETURNING token_hash`,
      [deviceId, userId],
    );
    for (const row of result.rows) {
      this.cache.delete(row.token_hash);
    }
    this.lastTouch.delete(deviceId);
    return (result.rowCount ?? 0) > 0;
  }

  async verify(token: string): Promise<DeviceIdentity | null> {
    const hash = hashDeviceToken(token);
    const now = Date.now();
    const cached = this.cache.get(hash);
    if (cached && cached.expiresAt > now) {
      return cached.identity;
    }

    const result = await this.pool.query<{
      id: string;
      user_id: string;
      name: string;
    }>(
      `SELECT d.id, d.user_id, u.name
       FROM devices d
       JOIN users u ON u.id = d.user_id
       WHERE d.token_hash = $1 AND d.revoked_at IS NULL`,
      [hash],
    );
    const row = result.rows[0];
    const identity = row
      ? { deviceId: row.id, userId: row.user_id, userName: row.name }
      : null;
    this.cache.set(hash, {
      identity,
      expiresAt: now + (identity ? CACHE_TTL_MS : NEGATIVE_CACHE_TTL_MS),
    });
    return identity;
  }

  /** Records device liveness, throttled to one write per few minutes. */
  async touch(deviceId: string): Promise<void> {
    const now = Date.now();
    const last = this.lastTouch.get(deviceId) ?? 0;
    if (now - last < TOUCH_INTERVAL_MS) {
      return;
    }
    this.lastTouch.set(deviceId, now);
    await this.pool.query(
      "UPDATE devices SET last_seen_at = now() WHERE id = $1",
      [deviceId],
    );
  }
}
