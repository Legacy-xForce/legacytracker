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

Only Android and iOS targets are supported. Android releases are built with
`scripts/release-android.sh` from the repository root.
