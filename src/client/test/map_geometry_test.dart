import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:legacytracker/src/features/tracking/widgets/map_geometry.dart';

void main() {
  group('clusterMarkers', () {
    test('groups neighbouring markers and leaves far ones alone', () {
      final entries = [
        const ClusterInput(value: 'a', point: LatLng(45.0700, 7.6860)),
        const ClusterInput(value: 'b', point: LatLng(45.0704, 7.6866)),
        const ClusterInput(value: 'c', point: LatLng(45.0900, 7.7200)),
      ];

      final groups = clusterMarkers(entries, zoom: 15);

      expect(groups, hasLength(2));
      expect(groups.first.members.map((m) => m.value), ['a', 'b']);
      expect(groups.last.members.single.value, 'c');
    });

    test('keeps people apart when they are more than 100 m away', () {
      // Close on screen at zoom 3, but ~180 m apart in the world.
      final entries = [
        const ClusterInput(value: 'a', point: LatLng(45.0700, 7.6860)),
        const ClusterInput(value: 'b', point: LatLng(45.0716, 7.6860)),
      ];

      final groups = clusterMarkers(entries, zoom: 3);

      expect(groups, hasLength(2));
    });

    test('keeps people apart when their icons do not overlap', () {
      // 30 m apart, but zoomed in far enough for the icons to separate.
      final entries = [
        const ClusterInput(value: 'a', point: LatLng(45.0700, 7.6860)),
        const ClusterInput(value: 'b', point: LatLng(45.0703, 7.6860)),
      ];

      final groups = clusterMarkers(entries, zoom: 18, pixelRadius: 2);

      expect(groups, hasLength(2));
    });

    test('uses the running centroid for the bubble', () {
      final entries = [
        const ClusterInput(value: 'a', point: LatLng(45.0700, 7.6860)),
        const ClusterInput(value: 'b', point: LatLng(45.0704, 7.6868)),
      ];

      final group = clusterMarkers(entries, zoom: 15).single;

      expect(group.center.latitude, closeTo(45.0702, 1e-9));
      expect(group.center.longitude, closeTo(7.6864, 1e-9));
    });
  });

  group('circleRing', () {
    test('is closed and every vertex is at the requested radius', () {
      const center = LatLng(45.0703, 7.6869);
      final ring = circleRing(center, 120, segments: 32);

      expect(ring, hasLength(33));
      expect(ring.first.latitude, closeTo(ring.last.latitude, 1e-9));
      expect(ring.first.longitude, closeTo(ring.last.longitude, 1e-9));
      for (final point in ring) {
        // Spherical construction keeps the radius within a metre.
        expect(distanceMeters(center, point), closeTo(120, 1));
      }
    });

    test('scales with the radius', () {
      const center = LatLng(45.0703, 7.6869);
      final ring = circleRing(center, 250, segments: 16);
      for (final point in ring) {
        expect(distanceMeters(center, point), closeTo(250, 1));
      }
    });
  });

  test('distanceMeters matches a known latitude span', () {
    expect(
      distanceMeters(const LatLng(0, 0), const LatLng(1, 0)),
      closeTo(111195, 50),
    );
  });

  test('world projection grows by one scale per zoom level', () {
    const point = LatLng(45, 7);
    final zoom10 = worldX(point, 10);
    final zoom11 = worldX(point, 11);
    expect(zoom11, closeTo(zoom10 * 2, 1e-6));

    // Longitude maps linearly and the equator is the vertical midpoint.
    expect(
      worldX(LatLng(45, 0), 10),
      closeTo(worldX(LatLng(-45, 0), 10), 1e-9),
    );
    expect(
      worldY(const LatLng(0, 0), 10),
      closeTo(128 * math.pow(2, 10), 1e-6),
    );
  });

  test('projection clamps latitudes beyond the Mercator limit', () {
    final top = worldY(const LatLng(89, 0), 5);
    final limit = worldY(const LatLng(85.05112878, 0), 5);
    expect(top, closeTo(limit, 1e-9));
    expect(top, closeTo(0, 1e-6));
  });
}
