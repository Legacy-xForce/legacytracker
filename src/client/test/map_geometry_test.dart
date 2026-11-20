import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:legacytracker/src/features/tracking/widgets/map_geometry.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_map_layer.dart';

void main() {
  _styleMappingTests();
  _cameraBandTests();

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

    test('incremental centroids match the straightforward algorithm', () {
      // The hot path keeps running sums and compares squared pixel distance
      // instead of re-walking every group. Membership and bubble positions
      // must stay identical across zooms, radii and dense arrangements.
      var seed = 20261120;
      double next() {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed / 0x7fffffff;
      }

      final entries = [
        for (var i = 0; i < 60; i++)
          ClusterInput(
            value: i,
            point: LatLng(
              45 + (next() - 0.5) * 0.2,
              7.6869 + (next() - 0.5) * 0.2,
            ),
          ),
      ];

      for (final zoom in [3.0, 8.0, 12.5, 17.0]) {
        for (final pixelRadius in [2.0, 48.0, 96.0, 180.0]) {
          final actual = clusterMarkers(
            entries,
            zoom: zoom,
            pixelRadius: pixelRadius,
          );
          final expected = _referenceClusterMarkers(
            entries,
            zoom: zoom,
            pixelRadius: pixelRadius,
          );
          expect(
            actual.map((g) => g.members.map((m) => m.value).toList()).toList(),
            expected
                .map((g) => g.members.map((m) => m.value).toList())
                .toList(),
            reason: 'members at zoom $zoom, radius $pixelRadius',
          );
          for (var i = 0; i < actual.length; i++) {
            expect(
              actual[i].center.latitude,
              closeTo(expected[i].center.latitude, 1e-12),
            );
            expect(
              actual[i].center.longitude,
              closeTo(expected[i].center.longitude, 1e-12),
            );
          }
        }
      }
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

/// The clustering algorithm before the incremental-centroid optimisation,
/// kept as a reference so the fast version has to agree with it exactly.
List<MarkerGroup<T>> _referenceClusterMarkers<T>(
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

void _styleMappingTests() {
  group('mapboxStyleUri', () {
    test('maps the two basemaps to Mapbox Standard styles', () {
      expect(
        mapboxStyleUri(MapLayer.standard),
        'mapbox://styles/mapbox/standard',
      );
      expect(
        mapboxStyleUri(MapLayer.satellite),
        'mapbox://styles/mapbox/standard-satellite',
      );
    });

    test('terrain is gone from the layer list', () {
      expect(MapLayer.values.map((layer) => layer.name), [
        'standard',
        'satellite',
      ]);
    });
  });
}

void _cameraBandTests() {
  group('coveredMapHeight', () {
    test('is the covered fraction of the map height', () {
      expect(coveredMapHeight(0, 800), 0);
      expect(coveredMapHeight(0.4, 800), 320);
      expect(coveredMapHeight(0.35, 900), closeTo(315, 0.001));
      expect(coveredMapHeight(1, 800), 800);
    });

    test('never reports more than the map or a negative band', () {
      // A sheet dragged past the top, or a not-yet-laid-out map, must not turn
      // into camera padding bigger than the view.
      expect(coveredMapHeight(1.3, 800), 800);
      expect(coveredMapHeight(-0.2, 800), 0);
      expect(coveredMapHeight(0.5, 0), 0);
    });
  });
}
