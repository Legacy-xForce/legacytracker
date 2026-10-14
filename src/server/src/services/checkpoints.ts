export const MIN_CHECKPOINT_RADIUS_M = 10;
export const MAX_CHECKPOINT_RADIUS_M = 250;
export const MAX_CHECKPOINT_NAME_LENGTH = 60;

export type CheckpointInput = {
  name: string;
  latitude: number;
  longitude: number;
  radiusM: number;
};

export type CheckpointInputResult =
  | { ok: true; value: CheckpointInput }
  | { ok: false; error: string };

/** Trims and collapses internal whitespace, so "Home  " and "Home" collide. */
export function normalizeCheckpointName(name: string): string {
  return name.trim().replace(/\s+/g, " ");
}

/**
 * Validates a create/update body (snake_case, as received over the wire).
 * Every field is required: PATCH sends the full checkpoint, like the editor
 * does.
 */
export function validateCheckpointInput(body: unknown): CheckpointInputResult {
  if (body == null || typeof body !== "object") {
    return { ok: false, error: "Invalid body" };
  }
  const raw = body as Record<string, unknown>;

  if (typeof raw.name !== "string") {
    return { ok: false, error: "name is required" };
  }
  const name = normalizeCheckpointName(raw.name);
  if (name.length === 0) {
    return { ok: false, error: "name is required" };
  }
  if (name.length > MAX_CHECKPOINT_NAME_LENGTH) {
    return {
      ok: false,
      error: `name must be at most ${MAX_CHECKPOINT_NAME_LENGTH} characters`,
    };
  }

  const latitude = raw.latitude;
  const longitude = raw.longitude;
  if (
    typeof latitude !== "number" ||
    !Number.isFinite(latitude) ||
    latitude < -90 ||
    latitude > 90
  ) {
    return { ok: false, error: "latitude must be between -90 and 90" };
  }
  if (
    typeof longitude !== "number" ||
    !Number.isFinite(longitude) ||
    longitude < -180 ||
    longitude > 180
  ) {
    return { ok: false, error: "longitude must be between -180 and 180" };
  }

  const radiusM = raw.radius_m;
  if (
    typeof radiusM !== "number" ||
    !Number.isInteger(radiusM) ||
    radiusM < MIN_CHECKPOINT_RADIUS_M ||
    radiusM > MAX_CHECKPOINT_RADIUS_M
  ) {
    return {
      ok: false,
      error: `radius_m must be a whole number between ${MIN_CHECKPOINT_RADIUS_M} and ${MAX_CHECKPOINT_RADIUS_M}`,
    };
  }

  return { ok: true, value: { name, latitude, longitude, radiusM } };
}

/** Admins may change any checkpoint; everyone else only their own. */
export function canModifyCheckpoint(
  role: string | null | undefined,
  ownerId: string,
  userId: string,
): boolean {
  return role === "admin" || ownerId === userId;
}

export type ResolvableCheckpoint = {
  id: string;
  name: string;
  latitude: number;
  longitude: number;
  radiusM: number;
};

const EARTH_RADIUS_M = 6_371_000;

/** Great-circle distance in metres. */
export function haversineMeters(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(a)));
}

/**
 * The checkpoint a point is inside, if any. Overlaps go to the smallest
 * radius (the most specific place); ties go to the nearest center.
 */
export function resolveCheckpoint<T extends ResolvableCheckpoint>(
  latitude: number,
  longitude: number,
  checkpoints: readonly T[],
): T | null {
  let best: T | null = null;
  let bestDistance = Infinity;
  for (const checkpoint of checkpoints) {
    const distance = haversineMeters(
      latitude,
      longitude,
      checkpoint.latitude,
      checkpoint.longitude,
    );
    if (distance > checkpoint.radiusM) continue;
    if (
      best === null ||
      checkpoint.radiusM < best.radiusM ||
      (checkpoint.radiusM === best.radiusM && distance < bestDistance)
    ) {
      best = checkpoint;
      bestDistance = distance;
    }
  }
  return best;
}
