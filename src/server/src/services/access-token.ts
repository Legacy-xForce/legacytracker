import {
  errors as joseErrors,
  jwtVerify,
  type JWTPayload,
  type JWTVerifyGetKey,
} from "jose";

import type { ApiTokenScope } from "./api-tokens";
import { hasTrackerScope, isForTracker } from "./tracker-scope";

export type VerifierConfig = {
  jwks: JWTVerifyGetKey;
  issuer: string;
  // OIDC clients whose tokens the tracker takes (`client_id` of an access
  // token, `aud` of a logout token).
  allowedClients: readonly string[];
};

export type AccessTokenResult =
  | {
      ok: true;
      sub: string;
      payload: JWTPayload;
      // What the token may do here: `read` is turned away from writes the
      // same way a read-only API token is.
      scope: ApiTokenScope;
      // Set for tokens from Legacy Auth's OpenID Provider; null for the
      // legacy password-login tokens.
      clientId: string | null;
      // The OP session the token belongs to, for back-channel logout.
      sid: string | null;
    }
  | {
      ok: false;
      reason: string;
      detail?: string;
      forbidden?: boolean;
      // A legacy token reports that its account lost the tracker scope.
      lostTrackerScope?: boolean;
      sub?: string;
    };

export const BACKCHANNEL_LOGOUT_EVENT =
  "http://schemas.openid.net/event/backchannel-logout";

// Added next to the standard event when a logout is caused by the account
// losing access (tracker scope removed, account disabled or deleted), not
// by a sign-out. The tracker then deletes the user's API tokens too.
export const ACCESS_REVOKED_EVENT = "urn:legacy:event:access-revoked";

const READ_SCOPE = "tracker.read";
const WRITE_SCOPE = "tracker.write";

function isTyp(header: { typ?: string }, expected: string): boolean {
  const typ = header.typ?.toLowerCase();
  return typ === expected || typ === `application/${expected}`;
}

function verificationFailure(error: unknown): {
  ok: false;
  reason: string;
  detail: string;
} {
  const reason =
    error instanceof joseErrors.JWTExpired
      ? "token expired"
      : error instanceof joseErrors.JWSSignatureVerificationFailed
        ? "token signature invalid"
        : error instanceof joseErrors.JWTClaimValidationFailed
          ? `token ${error.claim} claim invalid`
          : "token verification failed";
  return {
    ok: false,
    reason,
    detail: error instanceof Error ? error.message : String(error),
  };
}

/**
 * Scope an OP access token carries for the tracker (RFC 9068 `scope`), or
 * null when it carries none.
 */
export function trackerScopeOf(payload: JWTPayload): ApiTokenScope | null {
  const scopes =
    typeof payload.scope === "string" ? payload.scope.split(" ") : [];
  if (scopes.includes(WRITE_SCOPE)) return "write";
  if (scopes.includes(READ_SCOPE)) return "read";
  return null;
}

/**
 * Verifies a bearer access token from Legacy Auth. Two shapes are accepted
 * while the apps move to OpenID Connect:
 *
 * - OP tokens (`typ: at+jwt`): `aud` must be the tracker, `client_id` one of
 *   ours, and `scope` decides between read and write.
 * - Legacy password-login tokens (`type: access`): the `scopes.tracker` flag
 *   grants everything, as before.
 */
export async function verifyAccessToken(
  token: string,
  config: VerifierConfig,
): Promise<AccessTokenResult> {
  let payload: JWTPayload;
  let header: { typ?: string };
  try {
    ({ payload, protectedHeader: header } = await jwtVerify(
      token,
      config.jwks,
      { algorithms: ["ES256"], issuer: config.issuer },
    ));
  } catch (error) {
    return verificationFailure(error);
  }

  const sub =
    typeof payload.sub === "string" && payload.sub.length > 0
      ? payload.sub
      : null;
  if (!sub) {
    return { ok: false, reason: "token is missing a subject claim" };
  }

  if (isTyp(header, "at+jwt")) {
    const clientId =
      typeof payload.client_id === "string" ? payload.client_id : null;
    if (!clientId || !config.allowedClients.includes(clientId)) {
      return {
        ok: false,
        reason: "token was issued to a client the tracker doesn't accept",
        detail: `client_id ${JSON.stringify(clientId)}`,
      };
    }
    if (!isForTracker(payload)) {
      return {
        ok: false,
        reason: "token was not issued for the tracker",
        detail: `aud ${JSON.stringify(payload.aud ?? null)}`,
      };
    }
    const scope = trackerScopeOf(payload);
    if (!scope) {
      return {
        ok: false,
        reason: "token carries no tracker scope",
        detail: `user ${sub}`,
        forbidden: true,
      };
    }
    return {
      ok: true,
      sub,
      payload,
      scope,
      clientId,
      sid: typeof payload.sid === "string" ? payload.sid : null,
    };
  }

  if (payload.type !== "access") {
    return { ok: false, reason: "not an access token" };
  }
  if (!hasTrackerScope(payload)) {
    return {
      ok: false,
      reason: "account lacks the tracker scope",
      detail: `user ${sub}`,
      forbidden: true,
      lostTrackerScope: true,
      sub,
    };
  }
  // Checked after the scope: a token without the scope has no tracker `aud`
  // either, and should keep getting the 403 above.
  if (!isForTracker(payload)) {
    return {
      ok: false,
      reason: "token was not issued for the tracker",
      detail: `aud ${JSON.stringify(payload.aud ?? null)}`,
    };
  }
  return { ok: true, sub, payload, scope: "write", clientId: null, sid: null };
}

export type LogoutTokenResult =
  | {
      ok: true;
      sub: string | null;
      sid: string | null;
      // The account lost access rather than signing out.
      accessRevoked: boolean;
    }
  | { ok: false; reason: string; detail?: string };

/**
 * Verifies an OpenID Connect back-channel logout token (Back-Channel Logout
 * 1.0, section 2.6).
 */
export async function verifyLogoutToken(
  token: string,
  config: VerifierConfig,
): Promise<LogoutTokenResult> {
  let payload: JWTPayload;
  let header: { typ?: string };
  try {
    ({ payload, protectedHeader: header } = await jwtVerify(
      token,
      config.jwks,
      {
        algorithms: ["ES256"],
        issuer: config.issuer,
        audience: [...config.allowedClients],
        maxTokenAge: "5 minutes",
      },
    ));
  } catch (error) {
    return verificationFailure(error);
  }

  if (!isTyp(header, "logout+jwt")) {
    return { ok: false, reason: "not a logout token" };
  }
  const events = payload.events;
  if (
    events == null ||
    typeof events !== "object" ||
    Array.isArray(events) ||
    typeof (events as Record<string, unknown>)[BACKCHANNEL_LOGOUT_EVENT] !==
      "object"
  ) {
    return { ok: false, reason: "logout token has no back-channel event" };
  }
  if (payload.nonce !== undefined) {
    return { ok: false, reason: "logout token carries a nonce" };
  }
  const sub =
    typeof payload.sub === "string" && payload.sub.length > 0
      ? payload.sub
      : null;
  const sid =
    typeof payload.sid === "string" && payload.sid.length > 0
      ? payload.sid
      : null;
  if (!sub && !sid) {
    return { ok: false, reason: "logout token names neither sub nor sid" };
  }
  return {
    ok: true,
    sub,
    sid,
    accessRevoked: ACCESS_REVOKED_EVENT in events,
  };
}
