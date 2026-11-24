export type HistoryRangeResult =
  { ok: true; from: Date; to: Date } | { ok: false; error: string };

/**
 * The history query fetches rows newest-first with one extra row, so a capped
 * answer is distinguishable without a second COUNT. Keeps the newest `limit`
 * rows and returns them in the chronological order the session builder needs.
 */
export function capHistoryRows<T>(
  newestFirst: readonly T[],
  limit: number,
): { rows: T[]; truncated: boolean } {
  const truncated = newestFirst.length > limit;
  const rows = truncated ? newestFirst.slice(0, limit) : [...newestFirst];
  return { rows: rows.reverse(), truncated };
}

/**
 * Validates the `from`/`to` of a history deletion. Both are required and the
 * window is capped, so a malformed or half-empty request can never wipe more
 * than a few weeks, let alone everything.
 */
export function parseHistoryRange(
  query: Record<string, string | undefined>,
  maxWindowMs: number,
): HistoryRangeResult {
  if (!query.from || !query.to) {
    return { ok: false, error: "`from` and `to` are required" };
  }
  const from = new Date(query.from);
  const to = new Date(query.to);
  if (Number.isNaN(from.getTime()) || Number.isNaN(to.getTime())) {
    return { ok: false, error: "Invalid from/to timestamp" };
  }
  if (to.getTime() < from.getTime()) {
    return { ok: false, error: "`to` must be after `from`" };
  }
  if (to.getTime() - from.getTime() > maxWindowMs) {
    return { ok: false, error: "The time range is too long" };
  }
  return { ok: true, from, to };
}
