import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

/// Basemaps offered to the user. Terrain was dropped with the Mapbox move;
/// Standard and Standard Satellite are the only styles.
enum MapLayer { standard, satellite }

/// The Mapbox style URI for a basemap choice, shared by every map screen.
String mapboxStyleUri(MapLayer layer) => switch (layer) {
  MapLayer.standard => MapboxStyles.STANDARD,
  MapLayer.satellite => MapboxStyles.STANDARD_SATELLITE,
};
