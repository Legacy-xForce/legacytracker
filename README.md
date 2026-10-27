# Legacy Tracker

Real-time location sharing for the Legacy group. A phone app records where you
go with a native tracking engine, a Fastify + PostGIS server serves it over REST
and WebSocket, and a browser map shows it to the people you choose. Sign-in is
delegated to Legacy Auth (OIDC + PKCE); there is no password form.

The web map is at [tracker.legacy-group.tech](https://tracker.legacy-group.tech),
with the public API reference under [`/docs`](https://tracker.legacy-group.tech/docs).

## Install

**Android** — install the `.apk` from the newest release. Once installed, the
app updates itself: the server polls these releases and tells phones to install.

<h3 align="center">
<a href="https://github.com/Legacy-xForce/legacytracker/releases/latest" target="_blank"><img src="https://img.shields.io/badge/Android-Download_.apk-3DDC84?style=for-the-badge&logo=android&logoColor=3DDC84&labelColor=0B0B0B&color=0B0B0B" alt="Download the Android APK" width="200"></a>
</h3>

**iOS / iPadOS** — add the source once, then install and update from
[SideStore](https://sidestore.io) (AltStore Classic works the same way). The app
is unsigned in the release; SideStore re-signs it with your own Apple ID, so
signing is per person and no developer account of ours is involved.

<h3 align="center">
<a href="https://altdirect.app/?url=https://github.com/Legacy-xForce/legacytracker/releases/latest/download/altstore-source.json" target="_blank"><img src="https://altdirect.app/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200"></a>
&nbsp;
<a href="https://github.com/Legacy-xForce/legacytracker/releases/latest/download/LegacyTracker.ipa" target="_blank"><img src="https://altdirect.app/assets/png/Download_Blue.png" alt="Download .ipa" width="200"></a>
</h3>

The first button opens the feed in your sideloading app through
[altdirect](https://altdirect.app), which only turns a source URL into a
deep link; the second downloads the IPA for a manual install. Add the feed by
hand instead if you prefer:

```
https://github.com/Legacy-xForce/legacytracker/releases/latest/download/altstore-source.json
```

Both platforms need one manual install. Sideloaded iOS builds get no push
notifications, which is the one thing they give up against TestFlight — see
[docs/app-updates.md](docs/app-updates.md) for what still works.

## Packages

| Path | Stack | What it is |
|---|---|---|
| [`src/client`](src/client) | Flutter 3.44 + Kotlin / Swift | Phone app. The tracking engine is native; Flutter is the UI. |
| [`src/server`](src/server) | Fastify, TypeScript, PostgreSQL/PostGIS | REST + WebSocket API, live-mode controller, FCM pushes, Android release feed. |
| [`src/web`](src/web) | Vue 3, Vite, Tailwind, Mapbox GL JS | Read-only browser map, API tokens, the API reference. |

## Development

```bash
mise install                # node 22, java 21, flutter 3.44
mise run server:dev         # ts-node dev server
mise run web:dev            # http://localhost:5173
mise run app:analyze        # flutter analyze
mise run app:test           # dart tests
mise run app:android-test   # kotlin engine tests
```

`mise run db:psql` reaches the local PostGIS container; **never** point a dev
server at the production database from a local `.env` — it is shared, and
opening a map sends "go live" pushes to every registered phone.

## Documentation

- [docs/location-tracking.md](docs/location-tracking.md) — the tracking engine, states and upload protocol
- [docs/app-updates.md](docs/app-updates.md) — releasing, signing, and the iOS source feed
- [docs/oidc-migration.md](docs/oidc-migration.md) — auth against Legacy Auth
- [docs/calendar-events.md](docs/calendar-events.md), [docs/web-app.md](docs/web-app.md), [docs/mapbox.md](docs/mapbox.md)
- [src/server/README.md](src/server/README.md) — full API reference
- [CLAUDE.md](CLAUDE.md) — architecture notes for humans and agents alike

## License

MIT — see [LICENSE.md](LICENSE.md).
