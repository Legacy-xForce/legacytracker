import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Web-Mercator helpers shared by the map. The map is always north-up, so a
/// plain projection is enough to decide whether two markers overlap on screen.
const double _maxMercatorLatitude = 85.05112878;
const double _earthRadiusMeters = 6371008.8;

double _clampLatitude(double latitude) =>
    latitude.clamp(-_maxMercatorLatitude, _maxMercatorLatitude).toDouble();

double _latitudeRadians(double latitude) =>
    _clampLatitude(latitude) * math.pi / 180;

/// World-pixel X (0..worldSize) at [zoom].
double worldX(LatLng point, double zoom) {
  final scale = 256.0 * math.pow(2.0, zoom);
  return (point.longitude + 180.0) / 360.0 * scale;
}

/// World-pixel Y (0..worldSize) at [zoom].
double worldY(LatLng point, double zoom) {
  final scale = 256.0 * math.pow(2.0, zoom);
  final sinLat = math.sin(_latitudeRadians(point.latitude));
  final y = 0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi);
  return y * scale;
}

/// Great-circle distance in metres.
double distanceMeters(LatLng a, LatLng b) {
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final dLat = lat2 - lat1;
  final dLon = (b.longitude - a.longitude) * math.pi / 180;
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * _earthRadiusMeters * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Average of a set of coordinates. Used for cluster bubbles, which sit at the
/// running centroid of their members.
LatLng averagePosition(Iterable<LatLng> points) {
  var lat = 0.0;
  var lng = 0.0;
  var count = 0;
  for (final point in points) {
    lat += point.latitude;
    lng += point.longitude;
    count++;
  }
  if (count == 0) return const LatLng(0, 0);
  return LatLng(lat / count, lng / count);
}

/// A marker candidate given to [clusterMarkers].
class ClusterInput<T> {
  const ClusterInput({required this.value, required this.point});

  final T value;
  final LatLng point;
}

/// A group of markers that the map draws as one bubble.
class MarkerGroup<T> {
  MarkerGroup(this.members);

  final List<ClusterInput<T>> members;

  LatLng get center => averagePosition(members.map((m) => m.point));
}

/// Folds markers that are close together on screen into one bubble.
///
/// Two markers join a group only when they are within [pixelRadius] at [zoom]
/// *and* within [maxMeters] of the group centroid. The pixel limit alone would
/// merge people kilometres apart as the map zooms out, while the metre limit
/// alone would keep two neighbours split even when their icons collide.
List<MarkerGroup<T>> clusterMarkers<T>(
  List<ClusterInput<T>> entries, {
  required double zoom,
  double pixelRadius = 96,
  double maxMeters = 100,
}) {
  if (entries.length <= 1) {
    return [
      for (final entry in entries) MarkerGroup<T>([entry]),
    ];
  }

  final groups = <MarkerGroup<T>>[];
  final screenCentroids = <math.Point<double>>[];
  for (final entry in entries) {
    final px = math.Point(worldX(entry.point, zoom), worldY(entry.point, zoom));
    var target = -1;
    for (var i = 0; i < groups.length; i++) {
      final centroid = groups[i].center;
      final dx = px.x - screenCentroids[i].x;
      final dy = px.y - screenCentroids[i].y;
      if (math.sqrt(dx * dx + dy * dy) <= pixelRadius &&
          distanceMeters(entry.point, centroid) <= maxMeters) {
        target = i;
        break;
      }
    }
    if (target == -1) {
      groups.add(MarkerGroup<T>([entry]));
      screenCentroids.add(px);
    } else {
      groups[target].members.add(entry);
      final centroid = groups[target].center;
      screenCentroids[target] = math.Point(
        worldX(centroid, zoom),
        worldY(centroid, zoom),
      );
    }
  }
  return groups;
}

/// A closed ring of [segments] points at [radiusMeters] around [center],
/// following the sphere so checkpoint circles stay accurate at any latitude.
List<LatLng> circleRing(
  LatLng center,
  double radiusMeters, {
  int segments = 64,
}) {
  if (segments < 3) {
    throw ArgumentError.value(segments, 'segments', 'must be at least 3');
  }
  final lat1 = center.latitude * math.pi / 180;
  final lon1 = center.longitude * math.pi / 180;
  final angular = radiusMeters / _earthRadiusMeters;
  final ring = <LatLng>[];
  for (var i = 0; i < segments; i++) {
    final bearing = 2 * math.pi * i / segments;
    final lat2 = math.asin(
      math.sin(lat1) * math.cos(angular) +
          math.cos(lat1) * math.sin(angular) * math.cos(bearing),
    );
    final lon2 =
        lon1 +
        math.atan2(
          math.sin(bearing) * math.sin(angular) * math.cos(lat1),
          math.cos(angular) - math.sin(lat1) * math.sin(lat2),
        );
    ring.add(
      LatLng(lat2 * 180 / math.pi, ((lon2 * 180 / math.pi + 540) % 360) - 180),
    );
  }
  ring.add(ring.first);
  return ring;
}
