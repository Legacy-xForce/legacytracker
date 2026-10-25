# Mapbox configuration

Status: provisioning notes for the migration tracked in
[#69](https://github.com/Legacy-xForce/legacytracker/issues/69). The web app and
the phone app render Mapbox Standard and Standard Satellite; Nominatim stays for
street names, place search and event geocoding.

## Tokens at a glance

| Token | Where it lives | Scopes | Restrictions |
|---|---|---|---|
| Web public `pk.*` | `VITE_MAPBOX_TOKEN` in the web build (public by design) | `styles:read`, `fonts:read` | Allowed URLs: production origins + `http://localhost:5173` (or a separate dev token) |
| Server secret `sk.*` | `MAPBOX_SECRET_TOKEN` in the tracker server environment only | `tokens:write`, `styles:read`, `fonts:read` | Never leaves the server, never committed, never logged |
| App temporary `tk.*` | Minted at runtime, held in client memory | `styles:read`, `fonts:read` | Expires within one hour; cannot be URL-restricted or revoked |

There is deliberately **no `MAPBOX_TOKEN_MOBILE`**. Release APKs contain no
Mapbox token; they obtain a temporary one from the tracker backend. A
`--dart-define=MAPBOX_TOKEN` remains available for the `main_mapcheck.dart`
harness and local app work only, and release builds must ignore it.

## One-time account setup (manual)

These steps need the Mapbox account owner; they cannot be done from the
repository.

1. Confirm the account is **not a trial**. Creating temporary tokens requires a
   payment method even while usage stays inside the free tier.
2. Create the **web public token** with `styles:read` and `fonts:read`, and add
   allowed URLs for every production origin plus `http://localhost:5173` (or a
   separate token for local development). Mapbox matches these against the
   `Referer` header; the web app sends `strict-origin-when-cross-origin`.
3. Create the **server secret token** with `tokens:write`, `styles:read` and
   `fonts:read`. Store it as `MAPBOX_SECRET_TOKEN` only in the server
   environment (Coolify), and set `MAPBOX_USERNAME` to the account username.
4. Add the web public token as the GitHub Actions secret `MAPBOX_TOKEN_WEB`.
   CI passes it to the web build as `VITE_MAPBOX_TOKEN`. Do not add a mobile
   token secret.
5. Optionally lower `MAPBOX_TOKEN_TTL_SECONDS` (default `3300`, maximum `3600`).
   The server renews tokens five minutes before they expire.

Never put the secret token in `.env.example`, a workflow, a client build, a
log line, or an issue/PR comment. If it leaks, rotate it in the Mapbox dashboard
and update the server environment; temporary tokens already issued remain valid
until they expire.

## Server token endpoint

`POST /api/v1/mapbox/token` is authenticated and session-only. OpenID Provider
sessions must belong to `AUTH_MOBILE_CLIENT` (`tracker-mobile`), so a web
session or a personal API token cannot mint map tokens.

```http
POST /api/v1/mapbox/token
Authorization: Bearer <app access token>
```

```json
{
  "token": "tk.eyJ1IjoibGVnYWN5LXRyYWNrZXIiLCJleHAiOjE3OTI5NDAwMDAsImlhdCI6MTc5MjkzNjcwMCwic2NvcGVzIjpbInN0eWxlczpyZWFkIiwiZm9udHM6cmVhZCJdfQ.signature",
  "expires_at": "2026-10-25T13:00:00.000Z"
}
```

The response carries `Cache-Control: no-store`. Errors:

| Status | Meaning |
|---|---|
| `401` | Missing or invalid session. |
| `403` | API token, web session, or a session without the tracker scope. |
| `503` | `MAPBOX_SECRET_TOKEN`/`MAPBOX_USERNAME` are unset, or Mapbox refused the request. The app should show a retryable error. |

The server calls Mapbox's
[`POST /tokens/v2/{username}`](https://docs.mapbox.com/api/accounts/tokens/)
with `styles:read` and `fonts:read`, and caches the result per user in memory
until `expires_at - 5 minutes`. Concurrent requests for the same user share one
Mapbox call. The Tokens API allows 100 requests per minute per account; a
55-minute TTL and per-user cache stay far below that for normal use.

The cache is in-memory: a server restart costs one mint per active user. The
endpoint logs failures (user id, HTTP status, safe message) but never the
secret or a minted token.

## Web

`src/web/src/config.ts` reads `VITE_MAPBOX_TOKEN`. The style IDs are
`mapbox://styles/mapbox/standard` and
`mapbox://styles/mapbox/standard-satellite`. The app applies the Standard
`lightPreset` (`day`/`night`) to match the light or dark theme and keeps
rotation and pitch disabled.

The production build fails with a clear message when `VITE_MAPBOX_TOKEN` is
missing, rather than shipping a map that cannot load a style. Local development
reads `.env.local`; see `src/web/.env.example`.

## App

The phone app fetches a token before creating `MapWidget`:

1. `POST /api/v1/mapbox/token` with the signed-in session.
2. `MapboxOptions.setAccessToken(token, true)` (persistent is optional; the
   token is short-lived).
3. Renew about five minutes before `expires_at` and set the new global token.
4. If a style fails after expiry, recreate the `MapWidget` with camera and
   selection restored. The spike in `main_mapcheck.dart` records whether an
   already-created map accepts the new token without recreation.

If the token service is unavailable, the app shows a retryable error instead of
a blank map; it does not fall back to an embedded token. The spike harness can
still take a development token directly:
`flutter run -t lib/main_mapcheck.dart --dart-define=MAPBOX_TOKEN=pk.…`.
Name the define only for debug/profile runs; release builds reject it.

## CSP

The web build's `_headers` allows only:

- `https://api.mapbox.com` for styles, glyphs, sprites, tiles and telemetry
  (`img-src` and `connect-src`);
- `https://events.mapbox.com` for telemetry (`connect-src`);
- the existing backend, Legacy Auth, Legacy Calendar and Nominatim origins;
- `blob:` workers, which Mapbox GL JS uses for its worker.

No OpenFreeMap, OpenStreetMap tile, Esri or OpenTopoMap host remains after the
migration. Mapbox's logo and attribution stay visible.

## Free tier and monitoring

- Web: 50,000 map loads per month.
- Mobile: 25,000 monthly active users.
- Exceeding the free tier needs a payment method. There is no code fallback;
  watch Mapbox usage statistics and record a billing decision before a large
  rollout.
- Temporary tokens require a payment method even inside the free tier.

## CI

- Web: the `web` job in `.github/workflows/ci.yml` maps the
  `MAPBOX_TOKEN_WEB` secret to `VITE_MAPBOX_TOKEN` for `npm run build`.
- Server: `npm test` and `npm run build` need no Mapbox credentials; the token
  service is unit-tested with an injected `fetch`.
- Android/iOS: no Mapbox build-time token is required or embedded.

## Checking a release APK

```bash
unzip -p build/app/outputs/flutter-apk/app-release.apk classes.dex | strings | grep -E 'pk\.|sk\.' && echo 'token found' || echo 'no Mapbox token in APK'
```

Also grep the Flutter assets and native libraries. The only acceptable `tk.*`
value is one fetched at runtime.

## Rotation and incident response

1. Rotate the leaked token in the Mapbox dashboard.
2. Update `MAPBOX_SECRET_TOKEN` (server) and/or `MAPBOX_TOKEN_WEB` (CI and the
   web host), then redeploy.
3. Temporary tokens already issued cannot be revoked; they stop working within
   an hour. If the leak came from a specific account, rotate that user's tracker
   session as well.
