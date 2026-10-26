import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:legacytracker/src/features/tracking/widgets/mapbox_map.dart';
import 'package:legacytracker/src/features/tracking/widgets/session_replay_screen.dart';

/// The route the travel-details replay draws: a dark casing under one coloured
/// run per speed band. The casing painting over the colour is what made the
/// whole path look black, so its colour, opacity and layer are pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<LatLng> track(int count) => [
    for (var i = 0; i < count; i++) LatLng(47 + i * 0.001, 8 + i * 0.001),
  ];

  group('buildSpeedRoute', () {
    test('draws one casing under one coloured run per speed band', () {
      final lines = buildSpeedRoute(
        points: track(8),
        speedsMps: const [0, 0, 10, 10, 20, 20, 30, 30],
      );

      final casings = lines
          .where((line) => line.layer == MapPolylineLayer.casing)
          .toList();
      final runs = lines
          .where((line) => line.layer == MapPolylineLayer.route)
          .toList();

      expect(casings, hasLength(1));
      expect(casings.single.width, 8);
      expect(runs.length, greaterThan(1));
      expect(runs.map((line) => line.color).toSet().length, runs.length);
      for (final run in runs) {
        expect(run.width, 5);
        expect(run.opacity, 1);
        expect(run.points.length, greaterThan(1));
      }
    });

    test('every line is emissive so the night preset cannot blacken it', () {
      // line-emissive-strength defaults to 0: under the style's night lighting
      // that drains a route to black even though its colour is a bright red.
      final lines = buildSpeedRoute(
        points: track(5),
        speedsMps: const [0, 5, 10, 15, 20],
      );

      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(line.emissiveStrength, 1);
      }
    });

    test('the casing is opaque black at 0.35, never a translucent colour', () {
      final lines = buildSpeedRoute(
        points: track(4),
        speedsMps: const [5, 5, 5, 5],
      );
      final casing = lines.singleWhere(
        (line) => line.layer == MapPolylineLayer.casing,
      );

      expect(casing.color, const Color(0xFF000000));
      expect(casing.color.toARGB32(), 0xFF000000);
      expect(casing.opacity, 0.35);
    });

    test('an even speed gives a single coloured run over the whole track', () {
      final points = track(6);
      final lines = buildSpeedRoute(
        points: points,
        speedsMps: List.filled(points.length, 12),
      );

      final run = lines.singleWhere(
        (line) => line.layer == MapPolylineLayer.route,
      );
      expect(run.points, points);
    });

    test('runs share their boundary point so the route has no gaps', () {
      final lines = buildSpeedRoute(
        points: track(9),
        speedsMps: const [0, 0, 0, 25, 25, 25, 5, 5, 5],
      );
      final runs = lines
          .where((line) => line.layer == MapPolylineLayer.route)
          .toList();

      expect(runs.length, greaterThan(1));
      for (var i = 1; i < runs.length; i++) {
        expect(
          runs[i].points.first,
          runs[i - 1].points.last,
          reason: 'run $i must start where run ${i - 1} ended',
        );
      }
    });

    test('a track with no shape draws nothing at all', () {
      expect(buildSpeedRoute(points: const [], speedsMps: const []), isEmpty);
      expect(buildSpeedRoute(points: track(1), speedsMps: const [4]), isEmpty);
    });

    test('missing speeds still draw a coloured route, not a bare casing', () {
      final lines = buildSpeedRoute(points: track(5), speedsMps: const []);
      final runs = lines.where((line) => line.layer == MapPolylineLayer.route);

      expect(runs, hasLength(1));
      expect(runs.first.color, isNot(const Color(0xFF000000)));
    });
  });

  group('ReplayTrack', () {
    // 40 fixes, ~11 m apart: at the 40 s target every segment stays inside
    // the [16, 3000] ms clamps, so the sum is exactly the target.
    final straight = [
      for (var i = 0; i < 40; i++) LatLng(0, i * 0.0001),
    ];

    test('covers the whole trip in about the target time', () {
      final replay = ReplayTrack(straight);
      expect(replay.durationMs, closeTo(40000, 200));
    });

    test('dense identical fixes still advance a step each', () {
      final still = List.generate(10, (_) => const LatLng(45.07, 7.69));
      final replay = ReplayTrack(still);
      expect(replay.durationMs, closeTo(16.0 * 9, 0.001));
    });

    test('a sparse straight is capped per segment', () {
      final replay = ReplayTrack([const LatLng(0, 0), const LatLng(0, 0.9)]);
      expect(replay.durationMs, closeTo(3000, 0.001));
    });

    test('positionAt interpolates and reports the last fix passed', () {
      final replay = ReplayTrack(straight);
      final step = replay.durationMs / 39;
      final mid = replay.positionAt(straight, step * 1.5);
      expect(mid.index, 1);
      expect(mid.point.longitude, closeTo(0.00015, 1e-9));

      expect(replay.positionAt(straight, -5).index, 0);
      expect(replay.positionAt(straight, -5).point.longitude, 0);
      final end = replay.positionAt(straight, replay.durationMs + 5);
      expect(end.index, straight.length - 1);
      expect(end.point.longitude, closeTo(0.0039, 1e-12));
    });

    test('fraction seeks land on the same fix as the clock', () {
      final replay = ReplayTrack(straight);
      final byFraction = replay.positionAtFraction(straight, 0.5);
      final byClock = replay.positionAt(straight, replay.durationMs * 0.5);
      expect(byFraction.index, byClock.index);
      expect(
        byFraction.point.longitude,
        closeTo(byClock.point.longitude, 1e-12),
      );
    });

    test('a single fix has no clock but still positions', () {
      const one = [LatLng(45.07, 7.69)];
      final replay = ReplayTrack(one);
      expect(replay.durationMs, 0);
      final fix = replay.positionAt(one, 100);
      expect(fix.index, 0);
      expect(fix.point.latitude, 45.07);
    });
  });
}
