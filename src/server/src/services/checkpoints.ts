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
  { ok: true; value: CheckpointInput } | { ok: false; error: string };

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
