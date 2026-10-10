import 'package:latlong2/latlong.dart';

class AppConstants {
  // Tracker backend. Point a debug build at a local server with
  // `flutter run --dart-define=BACKEND_URL=http://10.0.2.2:3000` (10.0.2.2 is
  // the host machine as seen from the Android emulator).
  static const backendBaseUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://tracker.legacy-group.tech',
  );

  // Default map center (San Francisco)
  static const defaultMapCenter = LatLng(37.7749, -122.4194);
  static const defaultZoom = 13.0;

  // Map zoom limits. minZoom is intentionally permissive: the camera bounds
  // constraint (see worldBounds) is what actually stops zoom-out once the world
  // fills the viewport, so it adapts to the screen size instead of a fixed floor.
  static const minZoom = 1.0;
  static const maxZoom = 18.0;

  // Web Mercator's latitude limit: tiles don't exist beyond this, so showing it
  // would reveal a grey void at the poles.
  static const double maxMercatorLatitude = 85.05112878;
}
