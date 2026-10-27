# Legacy Tracker phone app

Flutter UI for the Legacy Tracker Android/iOS app. A native tracking engine
records and uploads positions; Flutter renders the live map, people list,
history/replay, checkpoints and calendar events.

The map uses Mapbox Standard / Standard Satellite through
`mapbox_maps_flutter`. Release builds carry no Mapbox token: the app fetches a
short-lived temporary token from the tracker backend at runtime. See
`docs/mapbox.md` at the repository root for token provisioning, the spike
harness and the release-token check.

## Commands

```bash
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:3000   # debug/profile only
flutter run -t lib/main_mapcheck.dart --dart-define=MAPBOX_TOKEN=pk.…  # map spike
cd android && ./gradlew testDebugUnitTest                     # native engine tests
```

Only Android and iOS targets are supported.

## Installing the app

Both platforms install once by hand and take updates from there. Releases come
from `scripts/release-android.sh` (or the `Release Android and iOS` workflow),
which publishes the Android APK, an unsigned iOS IPA and the iOS source feed
generated from it.

**Android** — install the `.apk` from [the newest
release](https://github.com/Legacy-xForce/legacytracker/releases/latest). The
tracker server polls releases and tells installed phones to update themselves;
see `docs/app-updates.md`.

**iOS** — an app is signed by whoever installs it, not by us, so a phone adds a
source feed once and installs and updates through SideStore (or AltStore
Classic):

```
https://github.com/Legacy-xForce/legacytracker/releases/latest/download/altstore-source.json
```

One tap, via [altdirect](https://altdirect.app), which only turns that URL into
an `sidestore://source?url=` deep link:

```
https://altdirect.app/?url=https://github.com/Legacy-xForce/legacytracker/releases/latest/download/altstore-source.json&r=sidestore
```

SideStore builds the store page from the feed, re-signs the unsigned IPA with
your Apple ID, and later offers an **Update** button on the same page. A free
Apple ID holds three sideloaded apps and re-signs them every 7 days; a paid
developer account raises that to one year.

**No push notifications on iOS.** Each install belongs to its own user's signing
team, so the server's APNs key cannot address it. Tracking and live positions
keep working while the phone is awake — live mode is also driven by the upload
response, not only by push — but a stationary, backgrounded phone is not woken
when someone opens a map. Notifications need TestFlight or the App Store, where
we sign the binary. Details in the iOS sections of `docs/app-updates.md`.
