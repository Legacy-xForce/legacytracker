import 'package:latlong2/latlong.dart';

class AppConstants {
  // Default map center (San Francisco)
  static const defaultMapCenter = LatLng(37.7749, -122.4194);
  static const defaultZoom = 13.0;

  // Map zoom limits
  static const minZoom = 3.0;
  static const maxZoom = 18.0;

  // Note: map bounds controlled via map options in supported flutter_map versions.
}
