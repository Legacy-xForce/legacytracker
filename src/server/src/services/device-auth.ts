import crypto from "crypto";
import type { Pool } from "pg";

export interface DeviceIdentity {
  deviceId: string;
  userId: string;
  userName: string;
}

export interface DeviceAuthOptions {
  /** Token age after which an opted-in upload gets a replacement. */
  rotateAfterMs?: number;
  /** A replaced token came back — log it; the device itself stays live. */
  onReuse?: (device: { deviceId: string; userId: string }) => void;
}

interface CacheEntry {
  identity: DeviceIdentity | null;
  /** When the token was issued (0 for unknown tokens). */
  issuedAt: number;
  expiresAt: number;
}

interface TokenRow {
  id: string;
  user_id: string;
  name: string;
  token_hash: string;
  prev_token_hash: string | null;
  issued_at: Date;
}

// Live mode uploads a point every few seconds per device; caching keeps that
// from costing a DB round-trip each. Unknown tokens are cached briefly so a
// revoked device that keeps retrying doesn't hammer the table either.
const CACHE_TTL_MS = 5 * 60_000;
const NEGATIVE_CACHE_TTL_MS = 30_000;
const TOUCH_INTERVAL_MS = 5 * 60_000;
const ROTATE_AFTER_MS = 24 * 60 * 60_000;
// Long enough to cover a phone's next upload after someone else swapped its
// token first; older retired tokens are treated as merely unknown.
const HISTORY_RETENTION_DAYS = 30;

/** Idempotent DDL for device credentials, run at startup and by tests. */
export const DEVICE_SCHEMA: readonly string[] = [
  `CREATE TABLE IF NOT EXISTS devices (
     id text PRIMARY KEY,
     user_id text NOT NULL REFERENCES users(id),
     token_hash text NOT NULL UNIQUE,
     platform text,
     created_at timestamptz NOT NULL DEFAULT now(),
     last_seen_at timestamptz,
     revoked_at timestamptz
   )`,
  "CREATE INDEX IF NOT EXISTS devices_user_idx ON devices (user_id)",
  "ALTER TABLE devices ADD COLUMN IF NOT EXISTS prev_token_hash text",
  "CREATE UNIQUE INDEX IF NOT EXISTS devices_prev_token_hash_idx ON devices (prev_token_hash)",
  "ALTER TABLE devices ADD COLUMN IF NOT EXISTS token_issued_at timestamptz NOT NULL DEFAULT now()",
  `CREATE TABLE IF NOT EXISTS device_token_history (
     token_hash text PRIMARY KEY,
     device_id text NOT NULL REFERENCES devices(id),
     retired_at timestamptz NOT NULL DEFAULT now()
   )`,
  "CREATE INDEX IF NOT EXISTS device_token_history_device_idx ON device_token_history (device_id, retired_at)",
];

export function hashDeviceToken(token: string): string {
  return crypto.createHash("sha256").update(token, "utf8").digest("hex");
}

function newToken(): string {
  return crypto.randomBytes(32).toString("base64url");
}

/**
 * Long-lived, revocable upload credentials for the native tracking engine.
 *
 * The engine uploads while the app is closed — possibly for days — so it
 * can't rely on the short-lived JWT, and refreshing a rotating refresh token
 * from both the engine and the Dart auth layer would race. Instead the app
 * exchanges a valid JWT for a device token once, and the engine presents it
 * as `Authorization: Device <token>`. Only sha256(token) is persisted.
 *
 * The engine alone owns the token after that, so it can rotate without
 * racing: once a token is a day old, an upload's response carries its
 * replacement. The previous token keeps working until the replacement is
 * first used, in case that response never arrived. A token that comes back
 * after being replaced means a second copy exists: the server logs it and
 * consumes that hash without issuing a replacement, so the copy stops
 * working while the real phone keeps tracking with its current token. No
 * credential is ever handed to whoever triggered a reuse warning.
 */
export class DeviceAuth {
  private readonly cache = new Map<string, CacheEntry>();
  private readonly lastTouch = new Map<string, number>();
  private readonly rotateAfterMs: number;
  private readonly onReuse: DeviceAuthOptions["onReuse"];

  constructor(
    private readonly pool: Pool,
    options: DeviceAuthOptions = {},
  ) {
    this.rotateAfterMs = options.rotateAfterMs ?? ROTATE_AFTER_MS;
    this.onReuse = options.onReuse;
  }

  async register(
    userId: string,
    platform: string | null,
    replacesDeviceId: string | null,
  ): Promise<{ deviceId: string; token: string }> {
    const token = newToken();
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
    const result = await this.pool.query<{
      token_hash: string;
      prev_token_hash: string | null;
    }>(
      `UPDATE devices SET revoked_at = now()
       WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
       RETURNING token_hash, prev_token_hash`,
      [deviceId, userId],
    );
    for (const row of result.rows) {
      this.cache.delete(row.token_hash);
      if (row.prev_token_hash) this.cache.delete(row.prev_token_hash);
    }
    this.lastTouch.delete(deviceId);
    return (result.rowCount ?? 0) > 0;
  }

  /**
   * @param allowRetired only the upload route may accept a retired token,
   * and only because it immediately replaces it. Routes that revoke or
   * otherwise mutate device state must use the default, strict behaviour.
   */
  async verify(
    token: string,
    allowRetired = false,
  ): Promise<DeviceIdentity | null> {
    const hash = hashDeviceToken(token);
    const now = Date.now();
    const cached = this.cache.get(hash);
    if (cached && cached.expiresAt > now) {
      return cached.identity;
    }

    const row = await this.lookup(hash);
    if (!row) {
      if (!allowRetired) {
        // Do not cache the refusal: a strict route (e.g. revoke) may see a
        // retired token moments before the upload path, which must still be
        // able to recognise and replace it.
        return null;
      }
      // A retired token came back: a second copy of it exists. Keep the
      // device alive and accept this upload — `rotateIfDue` gives the engine
      // a fresh token in the response, so tracking continues in the
      // background and the user never has to open the app. Do not cache the
      // identity: the reuse must be seen (and the token consumed) on every
      // presentation until it is replaced.
      return this.reusedIdentity(hash);
    }

    const identity = {
      deviceId: row.id,
      userId: row.user_id,
      userName: row.name,
    };
    if (row.token_hash === hash) {
      if (row.prev_token_hash !== null) {
        // First use of the replacement: the phone has it, so the old token
        // can retire.
        await this.retirePrevious(row.id, hash, row.prev_token_hash);
      }
      this.cache.set(hash, {
        identity,
        issuedAt: row.issued_at.getTime(),
        expiresAt: now + CACHE_TTL_MS,
      });
    }
    // The previous token is never cached, so the first use of its
    // replacement shuts it out immediately.
    return identity;
  }

  /**
   * Replaces [token] once it is due, or again when the phone still presents
   * the previous token (the response carrying the replacement was lost).
   * Returns the new token, or null when nothing changed. A retired token is
   * consumed instead of replaced: the upload is accepted but no credential is
   * issued to whoever presented it. Only for opted-in uploads after [verify]
   * accepted the token.
   */
  async rotateIfDue(token: string): Promise<string | null> {
    const hash = hashDeviceToken(token);
    const now = Date.now();
    const cached = this.cache.get(hash);
    if (
      cached?.identity &&
      cached.expiresAt > now &&
      cached.issuedAt + this.rotateAfterMs > now
    ) {
      return null;
    }

    const row = await this.lookup(hash);
    // No live token matches: either it is retired (a copy came back) or it
    // was never ours. Kill the copy; never hand out a replacement here, since
    // the server cannot tell the victim from whoever duplicated the token.
    if (!row) {
      await this.consumeRetired(hash);
      return null;
    }
    const next = newToken();
    const nextHash = hashDeviceToken(next);

    if (row.token_hash === hash) {
      if (row.prev_token_hash !== null) return null;
      if (row.issued_at.getTime() + this.rotateAfterMs > now) return null;
      // Compare-and-swap: a concurrent rotation of the same token loses.
      const result = await this.pool.query(
        `UPDATE devices
         SET prev_token_hash = token_hash, token_hash = $3,
             token_issued_at = now()
         WHERE id = $1 AND token_hash = $2 AND prev_token_hash IS NULL
           AND revoked_at IS NULL
           AND token_issued_at <= now() - $4 * interval '1 millisecond'`,
        [row.id, hash, nextHash, this.rotateAfterMs],
      );
      if ((result.rowCount ?? 0) === 0) return null;
      this.cache.delete(hash);
      return next;
    }

    // Still on the previous token: replace the never-used current one. It
    // is retired rather than dropped, so a copy of it showing up later is
    // caught like any other replaced token.
    const result = await this.pool.query(
      `WITH replaced AS (
         UPDATE devices SET token_hash = $4, token_issued_at = now()
         WHERE id = $1 AND prev_token_hash = $2 AND token_hash = $3
           AND revoked_at IS NULL
         RETURNING id
       )
       INSERT INTO device_token_history (token_hash, device_id)
       SELECT $3, id FROM replaced`,
      [row.id, hash, row.token_hash, nextHash],
    );
    if ((result.rowCount ?? 0) === 0) return null;
    this.cache.delete(row.token_hash);
    return next;
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

  /** The live device whose current or previous token hashes to [hash]. */
  private async lookup(hash: string): Promise<TokenRow | null> {
    const result = await this.pool.query<TokenRow>(
      `SELECT d.id, d.user_id, u.name, d.token_hash, d.prev_token_hash,
              d.token_issued_at AS issued_at
       FROM devices d
       JOIN users u ON u.id = d.user_id
       WHERE (d.token_hash = $1 OR d.prev_token_hash = $1)
         AND d.revoked_at IS NULL`,
      [hash],
    );
    return result.rows[0] ?? null;
  }

  private async retirePrevious(
    deviceId: string,
    currentHash: string,
    previousHash: string,
  ): Promise<void> {
    const result = await this.pool.query(
      `WITH confirmed AS (
         UPDATE devices SET prev_token_hash = NULL
         WHERE id = $1 AND token_hash = $2 AND prev_token_hash = $3
         RETURNING id
       )
       INSERT INTO device_token_history (token_hash, device_id)
       SELECT $3, id FROM confirmed`,
      [deviceId, currentHash, previousHash],
    );
    if ((result.rowCount ?? 0) === 0) return;
    // Retention is best effort: the token is already retired and the upload
    // has been accepted, so a cleanup failure must not turn it into a 500.
    try {
      await this.pool.query(
        `DELETE FROM device_token_history
         WHERE device_id = $1 AND retired_at < now() - $2 * interval '1 day'`,
        [deviceId, HISTORY_RETENTION_DAYS],
      );
    } catch {
      // Leftover rows are harmless; the next retirement tries again.
    }
  }

  /**
   * A retired token only comes back if a second copy of it exists. Instead of
   * locking the real phone out (which would force the user to open the app to
   * re-register), keep the device alive and report the reuse. `rotateAfterReuse`
   * then hands the uploader a fresh token in the response and consumes this
   * one, so the copy stops working while tracking carries on.
   */
  private async reusedIdentity(hash: string): Promise<DeviceIdentity | null> {
    const result = await this.pool.query<{
      device_id: string;
      user_id: string;
      name: string;
    }>(
      `SELECT h.device_id, d.user_id, u.name
       FROM device_token_history h
       JOIN devices d ON d.id = h.device_id
       JOIN users u ON u.id = d.user_id
       WHERE h.token_hash = $1 AND d.revoked_at IS NULL`,
      [hash],
    );
    const row = result.rows[0];
    if (!row) return null;
    this.onReuse?.({ deviceId: row.device_id, userId: row.user_id });
    return { deviceId: row.device_id, userId: row.user_id, userName: row.name };
  }

  /**
   * A retired token came back, so a copy of it exists. Consume that hash: the
   * upload is accepted (no lockout), the reuse is logged by [reusedIdentity],
   * but whoever presented it gets no replacement and cannot use it again.
   *
   * The real phone does not need a replacement here. It always holds either
   * `token_hash` or `prev_token_hash`, and the rotation path above already
   * re-issues a fresh token when the phone presents the previous one. Leaving
   * the device row untouched also means a copy-holder cannot rotate the
   * device out from under the phone.
   */
  private async consumeRetired(hash: string): Promise<void> {
    await this.pool.query(
      "DELETE FROM device_token_history WHERE token_hash = $1",
      [hash],
    );
    this.cache.delete(hash);
  }
}
