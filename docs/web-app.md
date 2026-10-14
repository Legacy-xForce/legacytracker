# Web app

A browser client for watching the tracker map (`src/web`). It never shares the
viewer's own location. Vue 3, Vite, Tailwind 4, Pinia, Leaflet.

## Sign-in

Password sign-in against Legacy Auth (`/auth/login`, `/auth/refresh`). Passkeys
are not supported on the web: the passkey RP ID is `auth.legacy-group.tech`,
which a page on another origin cannot use.

- The access token is kept in memory only. The refresh token is stored in
  `localStorage`, so a reload resumes the session.
- Refresh tokens rotate. Concurrent refreshes in one tab share a request, and
  if another tab already used the stored token, the successor it saved is tried.
- Accounts without `scopes.tracker` see "Scope required"; disabled accounts
  (403 `Account disabled`) see "Access restricted". Both mirror the phone app.

## What it shows

- **Live map** over the tracker websocket (one-time ticket, backoff reconnect).
  The map tab is reported as active only while visible, so phones leave live
  mode when every browser tab is hidden; returning to the tab reconnects.
- **Saved places** (checkpoints) as named circles. Read-only; they are edited in
  the phone app. The toggle is remembered.
- **Travel history**: "History" on a person lists their sessions a day at a
  time, and a session replays at constant on-screen speed (1x/2x/4x) with a
  scrubber, like the phone app. Someone who hid from you shows "not sharing".
- **Events** from Legacy Calendar (yesterday to +60 days, refreshed every five
  minutes and when the tab returns). Locations are geocoded with Nominatim, one
  lookup at a time, and every answer is cached in `localStorage`. An event
  shows until it ends (or until midnight of its day without an end). The
  overlay, and its toggle, are absent for accounts without calendar access.

## Running locally

```bash
cd src/web
npm install
npm run dev      # http://localhost:5173
npm test
```

Production services are used unless overridden (copy `.env.example` to `.env`):
`VITE_BACKEND_URL`, `VITE_AUTH_URL`, `VITE_CALENDAR_URL`. When developing
against a local tracker server, use one with its own database and no
`FIREBASE_SERVICE_ACCOUNT_JSON`: with it set, opening the map sends "go live"
pushes to every registered device.

## Deploying (Cloudflare Pages)

| Setting | Value |
|---|---|
| Root directory | `src/web` |
| Build command | `npm run build` |
| Output directory | `dist` |
| Environment variables | optional `VITE_*` overrides above (build time) |

`public/_redirects` sends every path to `index.html`, so deep links work.

Legacy Auth allows any origin; the tracker server and Legacy Calendar echo the
request origin, so the Pages domain and preview URLs need no CORS changes.
