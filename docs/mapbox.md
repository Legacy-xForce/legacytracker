# Mapbox configuration

Status: provisioning and QA notes for the migration tracked in
[#69](https://github.com/Legacy-xForce/legacytracker/issues/69). This replaces
the old MapLibre assessment. The web app and the phone app render Mapbox
Standard and Standard Satellite; Nominatim stays for street names, place search
and event geocoding.

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
`mapbox://styles/mapbox/standard-satellite`. Both styles use Mapbox's
`lightPreset`. Lighting is a per-device preference in the web Appearance
dialog: **Auto** (the default) follows the local clock — dawn 05:00–08:00, day
08:00–17:00, dusk 17:00–20:00, night otherwise — and Dawn, Day, Dusk and Night
pin a preset. Rotation and pitch stay disabled.

The production build fails when `VITE_MAPBOX_TOKEN` is missing, rather than
shipping a map that cannot load a style. CI provides it via the `MAPBOX_TOKEN_WEB`
secret. Local development reads `.env.local` (copy from `.env.example`); see
`src/web/.env.example`.

## App

The phone app fetches a token through `MapboxTokenGate` before creating
`MapWidget`:

1. `POST /api/v1/mapbox/token` with the signed-in session.
2. `MapboxOptions.setAccessToken(token)`.
3. Re-check the token every 30 seconds. The service returns its cached token
   until five minutes before expiry, then mints a new one.
4. A refresh updates the global token in place; the existing map keeps its
   camera and annotations. `MapboxTokenGate` recreates the map only after a
   `MapLoadingError` (two automatic attempts), because a dead token is the case
   where the already-created map demonstrably needs a fresh widget.

While the first token loads the gate shows a spinner. If the backend cannot
mint one, it shows a "Map unavailable" card with **Retry**; it never falls back
to an embedded token. The token request has no body and deliberately sends no
`Content-Type` (Fastify rejects body-less JSON requests).

### Markers and annotations

- Live markers are native bitmaps built in `marker_icons.dart` and added to the
  style with `StyleManager.addStyleImage`. Point annotations reference the image
  id, so moving a marker only updates geometry, never the bitmap bytes.
- Markers are the web client's design, drawn into the bitmap: the avatar in a
  ring that leaves a 2 px band (57 px ring around the 53 px avatar; white; the
  accent colour on your own marker; grey when stale), a speed badge top-right
  (`km/h`) and a battery badge under the avatar (dark pill, accent for
  yourself, grey when stale). Selection and motion scale the annotation
  (1.18 / 1.08) rather than adding bitmaps.
- The moving pulse is its own annotation whose `iconSize` breathes between
  0.725 and 1 every 1.2 s (16 steps of 150 ms), because it has to change over
  time; the heading beam is a 56° cone reaching 77 px, rotated per annotation.
  Neither re-renders a bitmap per frame.
- Groups use the web's cluster bubble: up to three faces with a 2.5 px white
  ring, a `+N` overflow face and a tail dot on the shared location, at the web's
  52 / 9 / 14 px metrics. Clustering merges people only when they are within 96
  screen pixels **and** 100 m at the current zoom. The tap callback names the
  annotation but never the touch point, so each visible face also gets a
  transparent hit-area annotation (`clusterFace` layer, created above the
  bubbles, stacked leftmost-on-top like the web): tapping a face opens that
  person, anywhere else on the bubble keeps the zoom-to-separate tap.
- Calendar events use a rounded-square pin in the event colour; checkpoints are
  geodesic polygons whose radius is respected in metres, with the web's name
  pill (dark, pin glyph, 12 px semibold) as an image marker from zoom 13;
  replay routes are native polylines coloured by recorded speed.
- No Flutter view annotations are used anywhere.
- Mapbox delivers a tap only to the **topmost** annotation, so only the people,
  cluster, cluster-face, event and replay-endpoint layers subscribe to taps,
  plus the checkpoint polygon manager (tapping a circle opens that checkpoint's
  editor); beams, pulses and checkpoint name pills are decoration and must
  never sit between a finger and a person.
- Annotation managers are created once per map. On every `style.load` the
  widget re-adds style images and repopulates the managers: the sprite is wiped
  by a style switch, while the SDK re-adds the annotation layers themselves.
  The map listens for `style.load` through one controller, so switching
  Standard/Satellite does not leak or duplicate marker layers.

The Standard basemap follows the app theme (`lightPreset` `day`/`night`).
Rotation and pitch gestures are disabled on both clients.

### Draw order and error isolation

A Mapbox annotation manager is one style layer: markers, labels, checkpoint
circles and each route layer get their own, created in draw order - route
casing, route lines, checkpoint polygons, checkpoint name pills, heading beams,
base markers, events, clusters, cluster-face hit areas, people.

The replay route is a dark casing under speed-coloured runs, mirroring the
working web layer (`src/web/src/components/ReplayLayer.vue`: `line-color`
`#000` with `line-opacity` 0.35 at width 8, then `['get','color']` at width 5).

**The black path was lighting, not ordering.** `line-emissive-strength` defaults
to **0** on line annotations (and `fill-emissive-strength` on polygon ones),
while point annotations default their icon and text emission to **1**. With the
Standard style the scene lighting multiplies a non-emissive layer down, so in a
dark theme (`lightPreset: night`) the route rendered as a black line while the
markers stayed bright - and switching styles showed the real colours for a
moment, until the night lighting settled. Every route line now carries
`emissiveStrength: 1`, and both line managers and the checkpoint manager get the
same value through their manager-level setters (`setLineEmissiveStrength`,
`setFillEmissiveStrength`) because the native side may treat emission as a
layer-wide constant rather than a per-feature one. That is what marker icons
already do implicitly.

Two further rules keep the casing from ever replacing the route:

- The casing manager is created with `below: routeManager.id`, so the style is
  told to keep the coloured route above it. Creation order alone is not
  enough - after a style reload the SDK re-adds annotation layers itself - and
  `line-sort-key` is not either, because the native API also exposes it as a
  whole-layer constant (`setLineSortKey`), so a per-feature key is no promise.
  A native build that refuses the anchor falls back to a plain manager, which
  is survivable only because of the next rule.
- The casing is opaque black at `lineOpacity` 0.35 rather than a translucent
  black colour, so even a wrong order can only tint the route.

`buildSpeedRoute` produces one coloured run per speed band, each sharing its
boundary point with the next so the line has no gaps
(`test/session_replay_route_test.dart`).

**Playback runs on one clock.** `ReplayTrack` mirrors the web module of that
name: every fix gets a playback time (1x) from a constant on-screen pace -
40 s per trip, a 5 m/s floor, 16..3000 ms per segment - and the marker position
is interpolated linearly against elapsed time. Playing each fix as its own
animation made the marker race through dense stretches (turns, stops) and
teleport between raw fixes. The controller's value is the trip fraction, so
the slider, seeks and the speed options all work on the same monotonic clock,
and the clock/km-h read-outs rebuild only when the displayed value changes.
Marker and camera update **every animation frame** (the old 50 ms throttle was
the other half of the jank), the heading beam interpolates the short way round
between fixes instead of snapping at each one, and a speed change while
playing restarts the ticker at the current fraction - setting `duration` on a
running `AnimationController` does not re-rate it, so 2x/4x looked selected
but played at the old speed.

Every layer syncs through its own `try`/`catch` (`_attempt`), and a marker
whose bitmap fails to encode is parked in `_failedImages` rather than aborting
the pass. Before this, one rejected style image skipped every later layer, so a
single bad icon silently removed checkpoint names and the whole route. Failures
are printed once per distinct message as `Mapbox annotation sync failed …`,
which reaches `adb logcat -s flutter` even in a release build: that is how a
route line that fails to be created can be told apart from one created under
the casing.

### Attribution, logo and scale bar

Mapbox requires the logo and the text attribution to be on screen and legible
whenever its map is, and never obscured by app UI. Disabling either is a
Restricted API, so the app keeps both enabled and instead moves them where the
rule is satisfiable:

- The SDK default is the logo at bottom-left with a 4 px margin and the
  attribution icon 92 px from the left, both 4 px above the bottom edge —
  precisely the strip the collapsed tracking sheet paints over, which is why
  nothing was visible. `MapScene.bottomInset` carries the covered height and
  `_applyOrnaments` lifts both ornaments above it, keeping the 4 px gap. The
  drawer pushes a new inset on every extent change without a Flutter rebuild.
- The full text (`© Mapbox`, `© OpenStreetMap`, *Improve this map*) opens from
  that icon's dialog, the same compact treatment the web client uses
  (`PeersMap.vue` passes `attributionControl: false` and adds a compact
  `AttributionControl`).
- The band comes from the sheet's real size: `DraggableScrollableController`
  does not notify for its initial size, so the drawer reports its extent once
  after the first frame, and the map reports again when it is first laid out.
  Until both are known the inset is 0 - never a guess from the screen height,
  which used to lift the logo into the middle of the map on startup.
- The sheet opens on its own 15 ms timer stepping `jumpTo`: while a selection
  rebuilds the sheet under it, `DraggableScrollableController.animateTo`'s
  future can stay pending and the sheet silently never opens. A selection made
  on the map also calls `openPerson` on the drawer directly, so it does not
  depend on that prop update landing before the frame. `test/tracking_drawer_test.dart`
  pins the extent report, the direct open and the prop-driven open.
- The scale bar is switched off. It defaulted to the top-left corner, collided
  with the status pill and viewer row, and Mapbox does not require it.

Every field is passed on each `updateSettings`, including the ones that already
match the default: iOS releases before 2.31.1 reset omitted fields to their
defaults on a partial update, which would drop the ornaments back to the raw
bottom edge. Margins are logical pixels — the native mapping converts them with
`toDevicePixels`.

### Keeping the map cheap

The map is a platform view, so rebuilding the Flutter subtree around it to move
a pin costs far more than the move. Three rules avoid that:

- `MapboxMapWidget` builds its `MapWidget` once in `initState` and `build()`
  returns that cached instance, so no ancestor `setState` can re-mount it.
- Annotations live in a mutable `MapScene` (`ChangeNotifier`) that the caller
  owns. Position ticks update the lists and call `markChanged()`; the widget
  listens and diffs the annotations itself. Live tracking never calls
  `setState` for a moving peer, and the camera/sheet callbacks do the same.
- Motion ticks are throttled to 100 ms, camera publishes to 120 ms and only
  when the zoom moved ≥ 0.12 or a label threshold was crossed, and every
  annotation is compared against a spec string before it is written to native.

### Profile pictures

Legacy Auth serves `https://auth.legacy-group.tech/auth/profile-picture/<uuid>`,
but the tracker still carries an older `avatar_url` for accounts that set one
before Legacy Auth took over. Those legacy paths answer `200` with the single
page app's HTML, which decodes as a broken image, so nobody's photo shows.
`avatarCandidateUrls` lists the stored URL first and the Legacy Auth URL after
it, and both `UserAvatar` (`_FallbackNetworkImage`) and the map markers
(`MarkerIconFactory._loadAvatar`) walk the list until one decodes.

A marker is drawn with the person's initial immediately and re-rendered with the
photo when it arrives, because the icon id encodes the avatar state (`initial`,
`ready`, `failed`). The screens cache the returned bitmaps per marker key, so an
icon still being rendered when the factory announces new avatars would put the
pre-photo bitmap back into that cache and the initial would stick — visibly so at
the ends of a replay, where one speed bucket is reused. Each screen therefore
keeps an `_iconEpoch`, clears both caches when the factory notifies, and drops
any completion from an older epoch.

### Spike harness

The standalone harness renders the real map with moving peers, a cluster, a
stale peer, an event-style checkpoint and the token controls:

```bash
flutter run -t lib/main_mapcheck.dart -d <device> \
  --dart-define=MAPBOX_TOKEN=pk.…
```

Pass a second token to exercise runtime replacement without rebuilding the
widget:

```bash
flutter run -t lib/main_mapcheck.dart -d <device> \
  --dart-define=MAPBOX_TOKEN=pk.… \
  --dart-define=MAPBOX_TOKEN_ALT=pk.…
```

The status card shows the active token prefix and how many times a style has
loaded. **Apply/Switch token in place** sets the global token and reloads the
style on the existing `MapWidget`; a rising style count means the already-created
map accepted the new token. **Recreate map** exercises the fallback. Record on a
device: marker glide smoothness, cluster split at high zoom, sheet-inset
following, and the APK size/token scan below. The `MAPBOX_TOKEN` define is
ignored by release builds (the harness itself is not part of the release app).

## CSP

The web build's `_headers` allows only:

- `https://api.mapbox.com` for styles, glyphs, sprites, tiles and telemetry
  (`img-src` and `connect-src`);
- `https://events.mapbox.com` for telemetry (`connect-src`);
- the existing backend, Legacy Auth, Legacy Calendar and Nominatim origins;
- `blob:` workers, which Mapbox GL JS uses for its worker;
- `'wasm-unsafe-eval'` in `script-src`, which Mapbox Standard needs for its
  WebAssembly building and 3D features.

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
unzip -p build/app/outputs/flutter-apk/app-release.apk classes.dex | strings \
  | grep -E 'pk\.[A-Za-z0-9]{20,}|sk\.[A-Za-z0-9]{20,}|tk\.' \
  && echo 'token found' || echo 'no Mapbox token in APK'
```

Also grep the Flutter assets and native libraries. Qualify the `pk.`/`sk.`
patterns with a length, otherwise the word "Task." matches the naive `sk\.`
search. The only acceptable `tk.*` value is one fetched at runtime.

## Verification and QA notes (October 2026)

Run locally on the migration branch:

| Check | Result |
|---|---|
| `flutter analyze` | No issues |
| `flutter test` | 215 passed |
| `npm test` (server) | 116 passed |
| `npm run build` (server) | tsc clean |
| `npm run format:check` (web) | clean |
| `npm test` (web) | 194 passed (one API-docs timeout when run beside a Gradle build; clean when rerun alone) |
| `npm run build` (web, placeholder token) | built |

Release APK measured from the CI artifact for commit `258b2d7`
(`android-apk`, universal):

| | Pre-Mapbox build | Mapbox build |
|---|---|---|
| APK on disk | 56 MB | 129 MB |
| CI artifact (zip) | 27.4 MB | 60.1 MB |

The growth is the Mapbox Maps SDK plus its native libraries, accepted in #69
in exchange for keeping one universal APK. Token scan on the extracted release
APK:

```bash
cd /tmp/android-apk
unzip -p app-release.apk classes.dex | strings | grep -E 'pk\.[A-Za-z0-9]{20,}|sk\.[A-Za-z0-9]{20,}|tk\.'
```

No `pk.`/`sk.`/`tk.` token was found in any dex, native library or asset
(a naive `grep 'sk\.'` matches the word "Task.", so use the length-qualified
pattern above). The only `tk.*` value the app ever handles is the one fetched
at runtime.

Device QA still to record on real hardware: marker glide smoothness with
several peers, cluster split, follow camera with the expanded sheet, the logo
and attribution icon staying visible while the sheet slides between collapsed
and expanded, Standard/Satellite switching, light/dark `lightPreset`, replay
playback with the route still coloured under a dark theme, the checkpoint
radius at different zooms, and token refresh over a full expiry window. Use
`main_mapcheck.dart` and the status card described above.

Two things cannot be checked from the current aarch64 development box, so the
release APK has to come from CI:

- No emulator. `sdkmanager` offers no `emulator` package for `aarch64` (Google
  ships it for x86_64 only) and there is no `/dev/kvm`, so a virtual device
  cannot run here even with the system image installed. A physical Android
  device over ADB is the way to do the list above.
- No local release build. The snap Flutter channel downloads
  `…/android-*-release/linux-x64/gen_snapshot` but the AOT step looks for
  `linux-arm64/gen_snapshot`, so `flutter build apk --release` fails on this
  host (`flutter build apk --debug` and `flutter test` are fine). The
  `android-apk` CI job is the release gate; download its artifact for the
  token scan above. SDK licences, NDK 28.2.13676358, platform 36, build-tools
  36 and platform-tools are installed under `~/Android/Sdk`.

Flutter targets are now Android and iOS only; the `linux`, `macos`, `windows`
and `web` runner directories were removed along with the unused desktop/web
tooling. `flutter_map` and its raster tile layers are no longer dependencies.

## Rotation and incident response

1. Rotate the leaked token in the Mapbox dashboard.
2. Update `MAPBOX_SECRET_TOKEN` (server) and/or `MAPBOX_TOKEN_WEB` (CI and the
   web host), then redeploy.
3. Temporary tokens already issued cannot be revoked; they stop working within
   an hour. If the leak came from a specific account, rotate that user's tracker
   session as well.
