import 'package:latlong2/latlong.dart';

class AppConstants {
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
