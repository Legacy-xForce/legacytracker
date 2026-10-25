# Web app

A browser client for watching the tracker map (`src/web`). It never shares the
viewer's own location. Vue 3, Vite, Tailwind 4, Pinia, Mapbox GL JS.

## Sign-in

OpenID Connect against Legacy Auth's OpenID Provider (`config.authUrl` is the
issuer), as the public client `tracker-spa`: authorization code + PKCE with
`oauth4webapi` (`src/api/oidc.ts`). There is no login form: "Sign in with Legacy"
redirects to Legacy Auth's own page (password or passkey; someone already
signed in to another Legacy app goes straight through) and it redirects back to
`<origin>/callback`, which `main.ts` completes before the router starts. A new
domain only needs `https://<domain>/callback` (and `https://<domain>/` for
sign-out) registered on the client. See `docs/oidc-migration.md`.

- One grant covers two resources: the tracker token is asked for with
  `resource=urn:legacy:tracker`, the calendar token (for events on the map) by
  refreshing with `resource=urn:legacy:calendar`. Only when the tracker token's
  `scopes.calendar` says the account has the calendar: a refused refresh spends
  the refresh token.
- Access tokens are kept in memory only. The refresh token (and the ID token,
  the sign-out hint) are stored in `localStorage` (`legacytracker.oidc`), so a
  reload resumes the session. This is a deliberate trade-off for domain
  flexibility; the build writes a strict Content-Security-Policy to
  `_headers` (`vite.config.ts`).
- Refresh tokens rotate and the OP revokes the grant when an old one is reused,
  so every refresh runs under one Web Lock (`src/lib/lock.ts`) across tabs and
  reads the newest token from storage inside it. Removing the key in one tab
  signs out the others.
- An account the OP turns away (`error=access_denied`) gets one line on the
  sign-in screen. If the sign-in asked for the calendar, it is first retried for
  the tracker alone (no second password: the OP session already exists).
- A 403 `Missing tracker scope` from the server, a refused refresh, or a
  `signed_out` stream message (back-channel logout) ends the session.
- Sign-out clears storage and goes to the OP's `end_session_endpoint`, which
  ends the Legacy session for every app.
- Sessions from the old password login (`legacytracker.session`) keep
  refreshing through `/auth/refresh` until that fails.

## Look

It follows the phone app's design: Material 3, dark, seeded from teal (the
colours in `src/style.css` were read off the app), Roboto, and Material Symbols
rounded icons. Wide screens get the people sheet as a floating side panel;
narrow ones get the app's bottom sheet (tap or drag the header).

People look the same as on the phone: the same colour per person (the app's
palette and hash), the Legacy Auth profile picture
(`/auth/profile-picture/{id}`, the same place Legacy Calendar links to) or the
initial, a heading beam, pulse and speed badge on the move, and a battery
badge. Someone not heard from for 90 minutes is greyed out, never see-through.
People close together on screen fold into one bubble of faces; a face selects
that person, the rest of the bubble zooms in.

Markers are Vue components mounted into Mapbox markers and patched in place,
never rebuilt, so photos and animations don't flicker. Anything that follows a
moving point frame by frame (the selected person, a replay) pans with
`panBy`: resetting the view instead would make every tile layer drop and
reload its tiles.

## What it shows

- **Live map** over the tracker websocket (one-time ticket, backoff reconnect).
  The map tab is reported as active only while visible, so phones leave live
  mode when every browser tab is hidden; returning to the tab reconnects.
  Markers glide between fixes over about the time between them, as in the app,
  and a selected person stays centred in the uncovered part of the map until
  you pan away.
- **People**: you first, then everyone with a position, then those who hide
  from you. Each row shows the street (or the saved place they are in), how
  long they've been there, moving, or last seen, and battery. Selecting someone
  opens their details: speed, battery and "here for", today's trips, top and
  average speed, the switch to hide your location from them (an account
  setting, so it applies to your phone too), and their trip history.
- **Street names** come from Nominatim reverse geocoding. Every Nominatim
  request in the page (streets and event places) shares one throttle, one
  request per 1.1 s, and each person or trip end keeps at most one lookup
  waiting, for its newest position.
- **Saved places** (checkpoints): their names replace the street of anyone
  inside them, as on the phone, and the map draws them as light teal circles
  with a name pill (names are hidden zoomed out). Read-only; they are edited in
  the phone app. The toggle is remembered.
- **Trip history**: a month calendar marking the days with trips (a year
  back), the picked day's trips with where they started and ended, and a
  replay at constant on-screen speed (1x/2x/4x) with a scrubber. Someone who
  hid from you shows "not sharing". On your own history each trip has a
  delete button, and so does the day; both ask first, and neither can be
  undone. The same buttons are in the phone app.
- **Events** from Legacy Calendar (yesterday to +60 days, refreshed every five
  minutes and when the tab returns). Locations are geocoded with Nominatim and
  every answer is cached in `localStorage`. An event shows until it ends (or
  until midnight of its day without an end). The overlay, and its toggle, are
  absent for accounts without calendar access.

## API tokens and docs

The account menu has **Manage profile** (opens Legacy Auth's account page for
name, picture, password and passkeys), **API tokens** (create a read or write
token, copy it once, rotate or delete it; the phone app has the same under
Profile → Integrations) and **API documentation**, which opens `/docs`. That
page is public, so integrators can read it before signing in. It renders the
OpenAPI document in `src/lib/openapi.ts` with Scalar; keep it in step with
`src/server/README.md` when an endpoint changes.

## Running locally

```bash
cd src/web
npm install
npm run dev      # http://localhost:5173
npm test
```

Production services are used unless overridden (copy `.env.example` to `.env.local`):
`VITE_BACKEND_URL`, `VITE_AUTH_URL`, `VITE_CALENDAR_URL`, `VITE_CALENDAR_WEB_URL`.
`VITE_MAPBOX_TOKEN` is required for a production build: it is the public token
restricted to the app's origins (see [`mapbox.md`](mapbox.md)). When developing
against a local tracker server, use one with its own database and no
`FIREBASE_SERVICE_ACCOUNT_JSON`: with it set, opening the map sends "go live"
pushes to every registered device.

## Deploying (Cloudflare Pages)

| Setting | Value |
|---|---|
| Root directory | `src/web` |
| Build command | `npm run build` |
| Output directory | `dist` |
| Environment variables | `NODE_VERSION=22` (Vite 8 needs 20.19+ or 22.12+), plus optional `VITE_*` overrides above (build time) |

`public/_redirects` sends every path to `index.html`, so deep links work.

Legacy Auth allows any origin; the tracker server and Legacy Calendar echo the
request origin, so the Pages domain and preview URLs need no CORS changes.
