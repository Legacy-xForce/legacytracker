import 'dart:io';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

/// Single source of truth for how movement-driven tracking is tuned in both
/// isolates (the main UI isolate and the background foreground-service
/// isolate).
///
/// Pacing (`AGGRESSIVE` / `PASSIVE`, still delivered via FCM) no longer
/// controls *poll frequency* — instead it tunes the continuous position
/// stream's `distanceFilter` + accuracy and the batch-flush interval.
class TrackingTuning {
  TrackingTuning._();

  // distanceFilter (metres) — how far the device must move before the OS
  // emits the next stream point.
  static const int passiveDistanceM = 50;
  static const int aggressiveDistanceM = 12;
  static const int batterySavingDistanceM = 100;

  // flush cadence (ms) — the onRepeatEvent interval that drains the outbox to
  // the server.
  static const int passiveFlushMs = 30000;
  static const int aggressiveFlushMs = 5000;
  static const int batterySavingPassiveFlushMs = 60000;
  static const int batterySavingAggressiveFlushMs = 15000;

  // App-level sample gate — drops GPS jitter while stationary and caps row
  // volume at highway speed, independent of the OS distanceFilter.
  static const int minSampleIntervalMs = 3000;
  static const int minSampleDistanceM = 10;

  // Stationary heartbeat — guarantee a liveness point even when parked.
  static const int heartbeatMaxGapMs = 300000; // 5 min

  // Fallback poll — if the stream produces nothing for this long while
  // backgrounded (Doze batching), force a one-shot fix on the flush tick.
  static const int streamStallFallbackMs = 120000; // 2 min

  static int distanceFilterFor({
    required bool aggressive,
    required bool batterySaving,
  }) {
    if (batterySaving) return batterySavingDistanceM;
    return aggressive ? aggressiveDistanceM : passiveDistanceM;
  }

  static int flushIntervalFor({
    required bool aggressive,
    required bool batterySaving,
  }) {
    if (batterySaving) {
      return aggressive
          ? batterySavingAggressiveFlushMs
          : batterySavingPassiveFlushMs;
    }
    return aggressive ? aggressiveFlushMs : passiveFlushMs;
  }

  static LocationAccuracy accuracyFor({
    required bool aggressive,
    required bool batterySaving,
  }) {
    if (batterySaving) return LocationAccuracy.low;
    return aggressive ? LocationAccuracy.high : LocationAccuracy.medium;
  }

  /// Platform-specific [LocationSettings] for `Geolocator.getPositionStream`.
  ///
  /// On Android we intentionally do **not** set
  /// `foregroundNotificationConfig` — `flutter_foreground_task` already owns
  /// the foreground-service notification and two would conflict.
  static LocationSettings settingsFor({
    required bool aggressive,
    required bool batterySaving,
  }) {
    final accuracy = accuracyFor(
      aggressive: aggressive,
      batterySaving: batterySaving,
    );
    final distanceFilter = distanceFilterFor(
      aggressive: aggressive,
      batterySaving: batterySaving,
    );

    if (Platform.isIOS || Platform.isMacOS) {
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        activityType: ActivityType.automotiveNavigation,
        // Let iOS sleep the GPS when stationary in PASSIVE; keep it awake in
        // AGGRESSIVE so turns/stops aren't missed.
        pauseLocationUpdatesAutomatically: !aggressive,
        allowBackgroundLocationUpdates: true,
      );
    }
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        intervalDuration: Duration(
          milliseconds: aggressive ? 2000 : 10000,
        ),
      );
    }
    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }

  /// Whether [next] should be enqueued given the last accepted point
  /// [prevLat]/[prevLon]/[prevMs]. Pure so it can be unit-tested.
  static bool shouldEnqueue({
    required double? prevLat,
    required double? prevLon,
    required int? prevMs,
    required double nextLat,
    required double nextLon,
    required int nextMs,
  }) {
    if (prevLat == null || prevLon == null || prevMs == null) return true;
    if (nextMs - prevMs >= minSampleIntervalMs &&
        _metres(prevLat, prevLon, nextLat, nextLon) >= minSampleDistanceM) {
      return true;
    }
    return false;
  }

  /// Whether a stationary heartbeat point is due.
  static bool needsHeartbeat({required int? lastPointMs, required int nowMs}) {
    if (lastPointMs == null) return true;
    return nowMs - lastPointMs >= heartbeatMaxGapMs;
  }

  /// Whether the position stream looks stalled (Doze batching) and a
  /// one-shot fallback fix should be forced on the flush tick.
  static bool streamStalled({required int? lastPointMs, required int nowMs}) {
    if (lastPointMs == null) return true;
    return nowMs - lastPointMs >= streamStallFallbackMs;
  }

  /// Approximate great-circle distance in metres (equirectangular — plenty
  /// accurate at the <1 km scale this gate operates on).
  static double _metres(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusM = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final meanLat = _rad((lat1 + lat2) / 2);
    final x = dLon * math.cos(meanLat);
    return earthRadiusM * math.sqrt(dLat * dLat + x * x);
  }

  static double _rad(double deg) => deg * math.pi / 180.0;
}
