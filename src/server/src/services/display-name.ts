import type { JWTPayload } from "jose";

function readStringClaim(payload: JWTPayload, claim: string): string | null {
  const value = payload[claim];
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/**
 * The human-facing name from a Legacy Auth token. `display_name` preserves the
 * capitalization the user chose; `name` is the standard OIDC equivalent.
 * Login identifiers remain the fallback for tokens issued before display names.
 */
export function getDisplayNameFromToken(
  payload: JWTPayload,
  fallbackId: string,
): string {
  const candidates = [
    readStringClaim(payload, "display_name"),
    readStringClaim(payload, "name"),
    readStringClaim(payload, "preferred_username"),
    readStringClaim(payload, "username"),
    readStringClaim(payload, "nickname"),
    readStringClaim(payload, "email"),
  ];

  return (
    candidates.find(
      (candidate) => candidate != null && candidate !== fallbackId,
    ) ?? fallbackId
  );
}
