# Moving Legacy Tracker to OAuth2 / OpenID Connect

Status: plan, not started. Tracks the legacytracker part of
[legacy-auth#4](https://github.com/Legacy-xForce/legacy-auth/issues/4) (Phases 2 and 3).
Snapshot: legacytracker `3669a0f`, legacy-auth `db691ff` (OP merged in #5, clients seeded **disabled**),
legacy-calendar `c02297e`.

## Where we are

Both clients sign in with ROPC: they post the password (or a passkey assertion) to
`auth.legacy-group.tech/auth/login` and get a Legacy Auth access + refresh token.

| Piece | Today |
|---|---|
| Web (`src/web`) | Own login form (`LoginView.vue`). Access token in memory, refresh token in `localStorage` (`stores/session.ts`). Scope checks decode the JWT (`lib/jwt.ts`) and route to `AccessDeniedView.vue`. |
| Flutter (`src/client`) | Own login form + native passkey ceremony (`login_screen.dart`, `passkey_client.dart`, `attestation.dart`, `passkeys` package). Tokens in `SharedPreferences` (`token_storage.dart`). `AccountDisabledScreen` / `MissingScopeScreen` (`access_denied_screen.dart`). Passkey management screen calls `/auth/passkey/*` with the tracker token. |
| Server (`src/server`) | `getCurrentUserIdentity()` verifies ES256, `iss`, `type: access`, legacy `scopes.tracker` (403) then `aud ∋ tracker` (401). API tokens (`X-API-Token`) and device tokens (`Authorization: Device`) are separate credential classes. WebSocket uses single-use tickets. |
| Calendar events | Both clients call `calendar.legacy-group.tech/events` **with the tracker's own access token**; 401/403 hides the feature. |

Open items that touch this work: PR #56 (send `audience: "tracker"`, on hold, see legacy-auth#4 comment:
it breaks calendar events), issue #36 (device token minting from a stolen session).

## Where we are going

- **No login form anywhere in the tracker.** Signing in is a redirect (web) or a system browser sheet
  (Custom Tabs / `ASWebAuthenticationSession`) to Legacy Auth's `/authorize`, which renders the one shared
  sign-in page with password **and passkey**. A user already signed in to calendar or the console goes
  straight through (SSO).
- **No "Scope required" / "Access restricted" screens.** The OP refuses an account without the tracker scope
  or a disabled account itself (`error=access_denied` back at our redirect URI, or a failed sign-in at the
  OP). The tracker only needs one line of text on its sign-in screen ("This account can't use Legacy
  Tracker"), not a dedicated screen with retry/scope polling. Losing access mid-session = the next refresh
  fails = signed out.
- **Web is a public PKCE client** (`tracker-spa`) that talks to the OP directly. Access tokens in memory,
  refresh token in `localStorage`. Works from any domain registered as a redirect URI.
- **Mobile is a public PKCE client** (`tracker-mobile`, redirect `com.legacy.legacytracker:/oauth2redirect`)
  with tokens in the Keychain / EncryptedSharedPreferences.
- **Both get a calendar token from the same sign-in** (refresh with `resource=urn:legacy:calendar`).
- **Unchanged:** the tracker server stays a pure resource server (Bearer tokens), device tokens and the native
  engine, API tokens, WebSocket tickets, FCM, profile pictures (`/auth/profile-picture/{id}` is public).

## Decisions

1. **Web token storage. Decided:** browser-only public client, refresh token in `localStorage` (no BFF, no
   cookies). Keeps the web app deployable on any domain (Pages, custom domains, localhost) by registering a
   redirect URI. Accepted trade-off: an XSS could read the refresh token. Mitigated by a small XSS surface
   (Vue escaping, `v-html` only on our own static content, no third-party scripts), a CSP (2.6), OP refresh
   rotation with grant-wide revocation on reuse, refresh tokens that end with the OP session (≤ 30 days,
   immediately on sign-out), and a tracker-only audience. This waives legacy-auth#4's "no tokens in
   `localStorage`" criterion for the tracker; say so on the issue.
2. **Calendar events on the map. Decided:** a second, calendar-audience token from the same grant (refresh
   with `resource=urn:legacy:calendar`). One sign-in; needs the OP changes in Phase 0.
3. **Existing sessions at upgrade. Decided:** keep refreshing an existing ROPC session through
   `/auth/refresh` until it fails, then show the new sign-in. Users are not logged out by the update.
   Background tracking is unaffected either way (device token).
4. **Account management. Decided:** passkeys, password and picture move to Legacy Auth's `/settings` page;
   the apps link to it and the in-app passkey code is deleted. Tracked in
   [legacy-auth#7](https://github.com/Legacy-xForce/legacy-auth/issues/7).

## Phase 0: prerequisites outside this repo

Tracked in [legacy-auth#8](https://github.com/Legacy-xForce/legacy-auth/issues/8).

legacy-auth (small PR):

- **New public client `tracker-spa`** (`is_public: true`, no secret) with
  `openid profile offline_access tracker.read tracker.write calendar.read`, one redirect URI per domain
  (`https://<domain>/callback`, e.g. `tracker.legacy-group.tech`, `legacytracker.pages.dev`,
  `http://localhost:5173`) and the matching `post_logout_redirect_uris`. The seeded confidential
  `tracker-web` stays disabled (or is deleted).
- **CORS on `/token`:** `oidc-provider`'s default `clientBasedCORS` already allows a public client's
  redirect-URI origins and legacy-auth doesn't override it. Verify end to end through the Bun proxy (no
  duplicate or stripped `Access-Control-*` headers from `cors.ts`).
- **Optional secondary resources at consent.** `interaction.ts` denies the whole sign-in if *any* requested
  resource scope isn't entitled, so asking for `calendar.read` would lock out tracker users without a
  calendar. Add a per-client `primary_resource` (or `required_resources`): refuse only when the user lacks
  it, silently drop unentitled scopes of other resources.
- **Default resources per client.** AppAuth (Android and iOS) only takes `additionalParameters` as a map, so
  the mobile app cannot send `resource` twice. Let `defaultResource` return `[urn:legacy:tracker,
  urn:legacy:calendar]` for the tracker clients when the request names none (the SPA can then omit it too).
- **Register `calendar.read`** in `allowed_scopes` of `tracker-mobile` (read only; the tracker never writes events).
- **Test** (missing today, called out in legacy-auth#4): one grant for both resources, code exchanged with
  `resource=urn:legacy:tracker`, refreshed with `resource=urn:legacy:calendar` returns `aud: calendar`;
  a user without calendar still gets a tracker token and an `invalid_target`/`invalid_grant` for calendar.
- **`post_logout_redirect_uris` for `tracker-mobile`:** register `com.legacy.legacytracker:/logout`.
- **Back-channel for public clients:** set `backchannel_logout_uri` of `tracker-spa` and `tracker-mobile` to
  `https://tracker.legacy-group.tech/auth/backchannel-logout` (the tracker *server* receives it; see 1.3), and
  confirm the OP sends one when a user's tracker scope is removed or the account is disabled.
- **Mobile refresh-token lifetime.** `expiresWithSession: true` ends every refresh token with its OP session
  (14 days idle / 30 days absolute, or a sign-out in the phone's browser, which Custom Tabs share). Good for
  the web; for `tracker-mobile` it means a forced re-login at least monthly. Decide whether native clients
  are exempt (their tokens then end only by refresh TTL, logout from the app, scope loss or disabling).
- Flag separately (covered by legacy-auth#7): `authenticate()` in legacy-auth accepts any ES256 access token
  without checking `aud`, so a tracker OP token can manage the user's passkeys/password at Legacy Auth.

Ops: create `tracker-spa`, `enable` `tracker-mobile`. No secrets anywhere (both clients are public).

legacy-calendar: nothing to build, but add a test that it accepts an OP token with `aud: calendar` and
`client_id: tracker-spa` / `tracker-mobile` (it checks the legacy `type`/`scopes` claims, which the OP keeps),
and that its CORS allows the tracker web origins (the browser now calls it directly with the calendar token,
as today).

## Phase 1: server accepts OP tokens (backward compatible, ship first)

1.1 **Token verification** (`app.ts` `getCurrentUserIdentity`, `services/tracker-scope.ts`)
- Accept both shapes during the transition: OP tokens (`typ: at+jwt`, `aud: "tracker"`, `client_id`, `scope`)
  and legacy ROPC tokens (`type: access`, `scopes` object). Same `iss`, same JWKS.
- OP tokens: authorize by RFC 9068 `scope`: `tracker.read` for `GET` and the stream ticket, `tracker.write`
  for everything else. Reuse the method rules of `isAllowedForScope` (API tokens) so the two read/write
  models stay one. Legacy tokens keep the `scopes.tracker` check until Phase 4.
- 403 vs 401 stays on the wire for API clients, but neither app distinguishes them any more.
- Allow-list `client_id ∈ {tracker-spa, tracker-mobile}` (env `AUTH_ALLOWED_CLIENTS`).

1.2 **Device registration** (`POST /api/v1/devices`, issue #36): require `tracker.write` and, for OP tokens,
`client_id = tracker-mobile`. A token stolen from the web app can no longer mint device tokens. (Rotation from
closed PR #48 remains the real fix for #36; out of scope here.)

1.3 **Back-channel logout endpoint** `POST /auth/backchannel-logout` (form `logout_token`): verify it (ES256 via
JWKS, `iss`, `aud ∈ {tracker-spa, tracker-mobile}`, `typ: logout+jwt`, `events` holds
`http://schemas.openid.net/event/backchannel-logout`, no `nonce`), answer 204.
- **API-token purge moves here.** Today tokens are deleted when a scope-less JWT shows up; with the OP that never
  happens (no token is issued without the scope). On a logout token that reports lost access (or a disabled
  account) for `sub`, purge that user's API tokens. Keep the existing check for legacy tokens. Exact signal
  depends on what the OP sends (Phase 0).
- **Instant web sign-out (optional, cheap):** record the token's `sid` on each WebSocket ticket; on a logout
  token for that `sid`, send `{type:"signed_out"}` and close those sockets. The SPA then clears its tokens at
  once instead of at the next refresh.

1.4 Tests (`node:test`): sign `at+jwt` and `logout+jwt` tokens with a local JWKS (pattern from Phase 0 tests):
read vs write scope, wrong `aud`, unknown `client_id`, calendar token rejected, legacy token still accepted,
device registration rules, back-channel verification and purge.

## Phase 2: web app signs in through the OP

No server changes beyond Phase 1. Library: `oauth4webapi` (panva, browser-native, no deps) for discovery,
PKCE, the code exchange, ID-token checks and refresh.

2.1 **Sign-in** (`src/web/src/api/auth.ts` rewritten, `/callback` route)
- "Sign in" → create `code_verifier`, `state`, `nonce`, keep them plus `return_to` in `sessionStorage`, redirect
  to `/authorize` with `client_id=tracker-spa`, `redirect_uri=${location.origin}/callback`,
  `scope=openid profile offline_access tracker.read tracker.write calendar.read`, `prompt=consent` (required for
  `offline_access`; invisible), `code_challenge_method=S256`.
- `/callback`: check `state`; on `error=access_denied` show "This account can't use Legacy Tracker." on the
  sign-in screen; otherwise `POST /token` (`resource=urn:legacy:tracker`) with the verifier, validate the ID
  token (`iss`, `aud = tracker-spa`, `nonce`, signature), store, `history.replaceState` the code out of the URL,
  go to `return_to`.
- `redirect_uri` is always `location.origin + '/callback'`, so a new domain only needs registering at the OP.
  `config.authUrl` becomes the issuer; add `VITE_OIDC_CLIENT_ID` (default `tracker-spa`).

2.2 **Tokens** (`stores/session.ts`)
- `localStorage` (`legacytracker.oidc`): refresh token, its expiry, the ID token (logout hint).
- Memory: tracker access token, calendar access token (or "no calendar" after a refused refresh).
- On boot: no stored refresh token → sign-in screen. Otherwise refresh → map. Delete the old
  `legacytracker.session` key; an old ROPC session keeps working through `/auth/refresh` until it fails
  (decision 3), then the sign-in screen.

2.3 **Refresh across tabs.** The OP has no reuse grace, so two tabs refreshing the same token sign the user
out everywhere. Every refresh runs inside `navigator.locks.request('legacytracker-refresh', …)`: inside the
lock, re-read `localStorage`; if another tab already stored a newer refresh token, use it (and refresh only if
the access token in memory is still stale). Write the new refresh token to `localStorage` **before** using the
new access token. Within a tab, keep the existing single-flight promise. `invalid_grant` → clear storage →
sign-in screen. A `storage` event removing the key signs the other tabs out.

2.4 **Calendar token.** Refreshing with `resource=urn:legacy:calendar` also rotates the shared refresh token,
so it uses the same lock. **A refused refresh spends the refresh token at the OP** (verified in the
`oidc-two-resource-test` worktree of legacy-auth), so asking for a calendar token the user can't have would end
the tracker session too. Only ask when the tracker token says the user has it (legacy `scopes.calendar` today;
ask legacy-auth#8 for a stable signal before that claim is dropped), or get the OP to not spend the token on
`invalid_target` (requested in #8). `hasCalendarScope` becomes "a calendar token was issued". `api/calendar.ts` sends that token
instead of the tracker one; otherwise unchanged.

2.5 **Sign-out.** Clear storage and memory, then redirect to the OP `end_session_endpoint` with
`id_token_hint` and `post_logout_redirect_uri=${location.origin}/`. This ends the shared OP session (calendar too).
Sign-out elsewhere reaches the tab at its next refresh (≤ 15 min), or at once with 1.3's WebSocket message.

2.6 **CSP** as cheap XSS insurance: `public/_headers` on Pages (and the same header wherever else it is served):
`default-src 'self'; connect-src 'self' <backend> <auth> <calendar> wss:; img-src 'self' data: <auth> <tile hosts>;
script-src 'self'; style-src 'self' 'unsafe-inline' fonts.googleapis.com; font-src fonts.gstatic.com;
frame-ancestors 'none'`. Check against every tile layer and Nominatim before shipping.

2.7 **Cleanup in `src/web/src`**
- Delete `views/AccessDeniedView.vue`, the `access-denied` route, the form in `views/LoginView.vue`,
  `AccountDisabledError`/`markForbidden`, scope decoding in `lib/jwt.ts` (keep `sub`/`username` reads).
- `LoginView` becomes a card: brand, "Sign in with Legacy", the `access_denied` message.
- `api/tracker.ts`: 401 → one refresh + retry (as now), then sign-in; 403 → sign-out (access lost).
- `DocsView`/`apiDocs.ts`: "session" = an OP access token for the tracker; integrators use API tokens.
- `docs/web-app.md` Sign-in section; passkeys now work on the web (the OP page runs on the RP ID's origin).
- Tests (vitest): PKCE/callback (`state` mismatch, `access_denied`), cross-tab refresh (two stores sharing a
  fake `localStorage` and a fake lock), calendar refusal keeps the session, legacy session migration.

2.8 **Rollback:** `VITE_AUTH_MODE=legacy` keeps today's flow for one release (the server accepts both token
shapes until Phase 4), so reverting is a rebuild of the web app.

## Phase 3: mobile app

3.1 **Packages:** add `flutter_appauth` (AppAuth: Custom Tabs / `ASWebAuthenticationSession`, never a WebView)
and `flutter_secure_storage`; remove `passkeys`. Android: `manifestPlaceholders["appAuthRedirectScheme"] = "com.legacy.legacytracker"`.
iOS: URL type for the same scheme. (Note: the iOS bundle id is still `com.example.legacytracker`; the
custom scheme does not depend on it, but fix it before any App Store work.)
Fallback if AppAuth gets in the way: `flutter_web_auth_2` + PKCE and the token call in Dart.

3.2 **`AuthService` / `AuthProvider` rewrite**
- `signIn()` → `authorizeAndExchangeCode` against the discovery document, `clientId: tracker-mobile`,
  scopes as in 2.1, `promptValues: ['consent']`, no `resource` on the authorize request (OP default, Phase 0),
  token request `resource=urn:legacy:tracker`. Verify `nonce`.
  `access_denied` → `errorMessage = "This account can't use Legacy Tracker."`; user cancel → no error.
- New `TokenManager`: holds the tracker token, the calendar token (refresh with
  `resource=urn:legacy:calendar`) and the single refresh token. **All refreshes go through one queue**
  (parallel refreshes revoke the grant), the new refresh token is persisted before the access token is used.
  `invalid_grant` → signed out. Request the calendar token only when the tracker token shows calendar access
  (a refused refresh spends the refresh token, see 2.4).
- `TokenStorage` → `flutter_secure_storage`. Migration: read the old `SharedPreferences` keys once,
  keep that ROPC session via the legacy `/auth/refresh` until it fails (decision 3), then delete the keys.
- `accessDenial`, `retryAccess`, `_hasTrackerScope`, `hasCalendarScope` (JWT decoding) go.
- `freshAccessToken()` keeps its signature, so `RemoteBackend`, `TrackingController`, `DeviceService`, the
  services under `data/network/` don't change. Fix the `_auth.tokens!.accessToken` uses in `app.dart`
  (`_registerFcmToken`, `didChangeDependencies`) to go through it; they read a possibly expired token today.
- Logout: wipe locally first (stop engine, unregister device, as now), then `endSession` with `id_token_hint`
  and `com.legacy.legacytracker:/logout`; best effort offline.

3.3 **Screens**
- `login_screen.dart` → brand + "Sign in" button + error line + `AppUpdateBanner` (keep #57: updates install while signed out).
- Delete `access_denied_screen.dart`, `passkey_client.dart`, `attestation.dart`, `passkeys_screen.dart`, the
  passkey methods in `auth_service.dart`, `models/passkey.dart`.
- Profile tab: "Manage account (password, passkeys)" opens Legacy Auth's account page in the browser (decision 4).
- `app.dart` `_home`: initializing → spinner, signed out → sign-in screen, else the app. Nothing in between.

3.4 **Calendar** (`calendar_service.dart`, `calendar_events_provider.dart`): use the calendar token from
`TokenManager`; no token = feature hidden, as today.

3.5 **Shared OP session.** Custom Tabs share Chrome's cookies, so the app's grant hangs off the phone browser's
OP session: signing out of calendar *in the phone's browser* also signs the app out, and (unless Phase 0 exempts
native clients) the app re-asks for sign-in at least every 30 days. Tracking continues on the device token
throughout. Escape hatch if this annoys users: an ephemeral browser session (`preferEphemeralSession`), which
loses SSO with the browser.

3.6 **Minimum version** (needed before ROPC can be removed, legacy-auth#4 §1.8): add
`min_supported_code` to `/api/v1/app/android/latest` (env on the server) and a blocking "Update required"
screen built from the existing updater when `buildNumber < min`. Ship this in the same release.

3.7 Tests: `flutter test` for `TokenManager` (single-flight, rotation persisted, `invalid_grant`, calendar-only
refusal), provider state transitions, legacy-session migration. Manual: emulator against a local OP
(`issuer http://10.0.2.2:4000`), password + passkey via Custom Tab, SSO with the phone browser, cancel,
`access_denied`, logout. Release via `scripts/release-android.sh` with a build-number bump.

## Phase 4: cleanup (after the mobile release has soaked)

- Raise `min_supported_code` to the OIDC release.
- Server: stop accepting legacy ROPC tokens (no `client_id`) and the `scopes` object.
- Clients: delete the legacy refresh path, `VITE_AUTH_MODE=legacy` and the old storage migration.
- Close PR #56 as superseded (the OP sets `aud` per resource). Tell legacy-auth that the tracker no longer
  calls `/auth/login`, `/auth/refresh`, `/auth/passkey/*`, so `REQUIRE_AUDIENCE=true` and ROPC removal are unblocked
  for the tracker.
- Docs: `CLAUDE.md` (auth paragraph, scope screens, gotchas), `docs/web-app.md`, server README, `apiDocs.ts`.
  Update the local-dev memory: local OP instead of the fake Legacy Auth.

## Rollout order

| Step | Ships | Users notice | Revert |
|---|---|---|---|
| 0 | legacy-auth Phase 0 PR, client config | nothing | `OIDC_ENABLED=false` |
| 1 | server Phase 1 | nothing | redeploy previous image |
| 2 | web Phase 2 | web: redirect sign-in, passkeys on the web, SSO with calendar | rebuild with `VITE_AUTH_MODE=legacy` |
| 3 | app release (OIDC + min-version screen) | app: browser sign-in at next sign-in | old APK still works (ROPC alive) |
| 4 | cleanup | old builds forced to update | raise/lower `min_supported_code` |

Each step is independently deployable; ROPC stays alive at legacy-auth until step 4.

## Local development

Run legacy-auth from source with its own throwaway Postgres (never the shared `.env`), create `tracker-spa`
(`http://localhost:5173/callback`) and `tracker-mobile` through the admin API, point the tracker server at it with
`AUTH_ISSUER`/`AUTH_JWKS_URI` and the web app with `VITE_AUTH_URL`, and keep `DATABASE_URL` on PGlite and
`FIREBASE_SERVICE_ACCOUNT_JSON=''` as usual. The OP's cookie is plain `legacy_session` on http.
