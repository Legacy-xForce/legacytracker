import type { JWTPayload } from "jose";

/**
 * Whether an access token grants use of the tracker. Legacy Auth puts each
 * account's per-app permissions in a `scopes` object
 * (`{ calendar: boolean, tracker: boolean }`), read fresh from its database
 * whenever a token is issued or refreshed.
 */
export function hasTrackerScope(payload: JWTPayload): boolean {
  const scopes = payload.scopes;
  return (
    scopes != null &&
    typeof scopes === "object" &&
    !Array.isArray(scopes) &&
    (scopes as Record<string, unknown>).tracker === true
  );
}

/**
 * Whether Legacy Auth issued the token for the tracker. Its signing key is
 * shared by every app, so `aud` is what keeps a token meant for another app
 * (e.g. the calendar) from being replayed here.
 */
export function isForTracker(payload: JWTPayload): boolean {
  const { aud } = payload;
  return aud === "tracker" || (Array.isArray(aud) && aud.includes("tracker"));
}
