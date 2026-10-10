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
