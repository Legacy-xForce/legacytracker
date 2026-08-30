import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/features/location/tracking_tuning.dart';

void main() {
  group('distanceFilterFor', () {
    test('battery saving wins over pacing', () {
      expect(
        TrackingTuning.distanceFilterFor(aggressive: true, batterySaving: true),
        TrackingTuning.batterySavingDistanceM,
      );
    });

    test('aggressive tightens the filter', () {
      expect(
        TrackingTuning.distanceFilterFor(
          aggressive: true,
          batterySaving: false,
        ),
        TrackingTuning.aggressiveDistanceM,
      );
      expect(
        TrackingTuning.distanceFilterFor(
          aggressive: false,
          batterySaving: false,
        ),
        TrackingTuning.passiveDistanceM,
      );
    });
  });

  group('flushIntervalFor', () {
    test('aggressive flushes faster than passive', () {
      expect(
        TrackingTuning.flushIntervalFor(aggressive: true, batterySaving: false),
        lessThan(
          TrackingTuning.flushIntervalFor(
            aggressive: false,
            batterySaving: false,
          ),
        ),
      );
    });

    test('battery saving slows the flush', () {
      expect(
        TrackingTuning.flushIntervalFor(
          aggressive: false,
          batterySaving: true,
        ),
        greaterThan(
          TrackingTuning.flushIntervalFor(
            aggressive: false,
            batterySaving: false,
          ),
        ),
      );
    });
  });

  group('shouldEnqueue', () {
    test('first point always passes', () {
      expect(
        TrackingTuning.shouldEnqueue(
          prevLat: null,
          prevLon: null,
          prevMs: null,
          nextLat: 45.0,
          nextLon: 7.0,
          nextMs: 1000,
        ),
        isTrue,
      );
    });

    test('rejects a jittery point too close in time and space', () {
      expect(
        TrackingTuning.shouldEnqueue(
          prevLat: 45.0,
          prevLon: 7.0,
          prevMs: 1000,
          nextLat: 45.00001,
          nextLon: 7.00001,
          nextMs: 1500,
        ),
        isFalse,
      );
    });

    test('accepts a point that moved far enough after enough time', () {
      expect(
        TrackingTuning.shouldEnqueue(
          prevLat: 45.0,
          prevLon: 7.0,
          prevMs: 1000,
          nextLat: 45.001, // ~111 m north
          nextLon: 7.0,
          nextMs: 10000,
        ),
        isTrue,
      );
    });
  });

  group('needsHeartbeat / streamStalled', () {
    test('heartbeat due after the max gap', () {
      expect(
        TrackingTuning.needsHeartbeat(lastPointMs: 0, nowMs: 299000),
        isFalse,
      );
      expect(
        TrackingTuning.needsHeartbeat(lastPointMs: 0, nowMs: 301000),
        isTrue,
      );
    });

    test('stream considered stalled with no points yet', () {
      expect(
        TrackingTuning.streamStalled(lastPointMs: null, nowMs: 5000),
        isTrue,
      );
    });
  });
}
