export const MIN_CHECKPOINT_RADIUS_M = 10;
export const MAX_CHECKPOINT_RADIUS_M = 250;
export const MAX_CHECKPOINT_NAME_LENGTH = 60;

export type CheckpointInput = {
  name: string;
  latitude: number;
  longitude: number;
  radiusM: number;
  /**
   * One emoji, or an empty string for none. `null` means the body omitted it:
   * a PATCH then keeps the stored emoji instead of clearing it.
   */
  emoji: string | null;
};

export type CheckpointInputResult =
  { ok: true; value: CheckpointInput } | { ok: false; error: string };

/** Trims and collapses internal whitespace, so "Home  " and "Home" collide. */
export function normalizeCheckpointName(name: string): string {
  return name.trim().replace(/\s+/g, " ");
}

const graphemeSegmenter = new Intl.Segmenter(undefined, {
  granularity: "grapheme",
});

/** One emoji may be a long grapheme cluster (family, flag, skin tone). */
function graphemeCount(value: string): number {
  return [...graphemeSegmenter.segment(value)].length;
}

/**
 * Validates the optional emoji. `undefined`/`null` mean "not supplied"; an
 * empty string is an explicit "no emoji". Anything longer than one grapheme
 * cluster (or with control characters) is refused.
 */
function validateCheckpointEmoji(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") return undefined;
  const emoji = value.trim();
  if (emoji.length === 0) return value.length === 0 ? "" : undefined;
  if (graphemeCount(emoji) !== 1) return undefined;
  // Tab, newline and friends are not emoji even when they fit in a grapheme.
  if (/\p{Cc}/u.test(emoji)) return undefined;
  // A single letter is one grapheme too; require an actual pictograph. Flags
  // are regional indicators and keycaps carry U+20E3, neither of which is
  // Extended_Pictographic on its own.
  if (!/[\p{Extended_Pictographic}\p{Regional_Indicator}\u20E3]/u.test(emoji)) {
    return undefined;
  }
  return emoji;
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

  const emoji = validateCheckpointEmoji(raw.emoji);
  if (emoji === undefined) {
    return { ok: false, error: "emoji must be a single emoji or empty" };
  }

  return { ok: true, value: { name, latitude, longitude, radiusM, emoji } };
}

/** Admins may change any checkpoint; everyone else only their own. */
export function canModifyCheckpoint(
  role: string | null | undefined,
  ownerId: string,
  userId: string,
): boolean {
  return role === "admin" || ownerId === userId;
}
