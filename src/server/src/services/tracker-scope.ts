import type { JWTPayload } from "jose";

/**
 * Whether Legacy Auth issued the token for the tracker. Its signing key is
 * shared by every app, so `aud` is what keeps a token meant for another app
 * (e.g. the calendar) from being replayed here.
 */
export function isForTracker(payload: JWTPayload): boolean {
  const { aud } = payload;
  return aud === "tracker" || (Array.isArray(aud) && aud.includes("tracker"));
}
