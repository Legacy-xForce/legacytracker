import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/location_model.dart';
import '../debug/debug_log_store.dart';
import '../location/location_outbox.dart';
import '../location/location_payload.dart';
import '../location/tracking_tuning.dart';

// Entry point called by flutter_foreground_task in its own isolate.
@pragma('vm:entry-point')
void backgroundTaskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(BackgroundLocationHandler());
}

/// Movement-driven background tracking.
///
/// A continuous, distance-filtered `getPositionStream` runs inside the
/// foreground-service isolate and feeds accepted points into [LocationOutbox].
/// `onRepeatEvent` is repurposed as a short flush tick that drains the outbox
/// to the server in a single batch, tops up a stationary heartbeat, and — if
/// the stream looks stalled under Doze — forces a one-shot fallback fix.
class BackgroundLocationHandler extends TaskHandler {
  StreamSubscription<Position>? _sub;
  final LocationOutbox _outbox = LocationOutbox();

  // Last point that passed the app-level sample gate.
  double? _lastLat;
  double? _lastLon;
  int? _lastAcceptedMs;
  // Last time the stream delivered anything at all (gate or not).
  int? _lastStreamMs;
  // Last time a point was enqueued or successfully sent — drives the
  // stationary heartbeat.
  int? _lastActivityMs;

  String _pacing = 'PASSIVE';
  bool _batterySaving = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    unawaited(
      DebugLogStore.log('lifecycle', 'Background task started (via $starter)'),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    _pacing = prefs.getString('pacing_mode') ?? 'PASSIVE';
    _batterySaving = prefs.getBool('battery_saving_enabled') ?? false;
    await _openStream();
  }

  Future<void> _openStream() async {
    await _sub?.cancel();
    final aggressive = _pacing == 'AGGRESSIVE';
    final settings = TrackingTuning.settingsFor(
      aggressive: aggressive,
      batterySaving: _batterySaving,
    );
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (Object e) {
        unawaited(DebugLogStore.log('position', 'Stream error: $e'));
      },
    );
    unawaited(
      DebugLogStore.log(
        'position',
        'Position stream opened (pacing=$_pacing, '
            'batterySaving=$_batterySaving)',
      ),
    );
  }

  Future<void> _onPosition(Position position) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _lastStreamMs = nowMs;
    unawaited(DebugLogStore.markTick());

    final pass = TrackingTuning.shouldEnqueue(
      prevLat: _lastLat,
      prevLon: _lastLon,
      prevMs: _lastAcceptedMs,
      nextLat: position.latitude,
      nextLon: position.longitude,
      nextMs: nowMs,
    );
    if (!pass) return;

    _lastLat = position.latitude;
    _lastLon = position.longitude;
    _lastAcceptedMs = nowMs;

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    // While the app is visible, the main isolate's stream + WebSocket already
    // cover uploads — keep the subscription alive (GPS warm / service
    // healthy) but don't enqueue.
    if (prefs.getBool('app_foreground') ?? false) return;

    await _enqueue(position, 'move');
  }

  Future<void> _enqueue(Position position, String source) async {
    final battery = await _readBattery();
    final payload = buildLocationPayload(
      LocationPoint(
        latitude: position.latitude,
        longitude: position.longitude,
        speed: position.speed >= 0 ? position.speed : 0.0,
        heading: position.heading.isFinite ? position.heading : null,
        timestamp: position.timestamp,
      ),
      batteryLevel: battery.$1,
      isCharging: battery.$2,
      source: source,
    );
    await _outbox.enqueue(payload);
    _lastActivityMs = DateTime.now().millisecondsSinceEpoch;
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    final appForeground = prefs.getBool('app_foreground') ?? false;
    final pacing = prefs.getString('pacing_mode') ?? 'PASSIVE';
    final batterySaving = prefs.getBool('battery_saving_enabled') ?? false;

    // Pacing / battery-saving changed → reopen the stream with new settings
    // and retarget the flush interval.
    if (pacing != _pacing || batterySaving != _batterySaving) {
      _pacing = pacing;
      _batterySaving = batterySaving;
      await _openStream();
      await _syncFlushInterval(prefs);
    }

    final accessToken = prefs.getString('auth_access_token');
    final baseUrl = prefs.getString('bg_base_url');
    if (accessToken == null || baseUrl == null) {
      unawaited(
        DebugLogStore.log('lifecycle', 'Flush skipped: not signed in'),
      );
      return;
    }

    if (!appForeground) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final lastPointMs = _lastActivityMs;

      // Fallback poll: the stream has produced nothing for too long (Doze
      // batching) — force a one-shot fix so freshness has a floor.
      if (TrackingTuning.streamStalled(
        lastPointMs: _lastStreamMs,
        nowMs: nowMs,
      )) {
        final position = await _oneShot();
        if (position != null) {
          _lastStreamMs = nowMs;
          await _enqueue(position, 'move');
        }
      } else if (TrackingTuning.needsHeartbeat(
        lastPointMs: lastPointMs,
        nowMs: nowMs,
      )) {
        // Stationary heartbeat: no point in a while, emit one anyway.
        final position =
            await Geolocator.getLastKnownPosition() ?? await _oneShot();
        if (position != null) {
          await _enqueue(position, 'heartbeat');
        }
      }
    }

    final batch = await _outbox.drain();
    if (batch.isEmpty) return;

    try {
      await _uploadLocation(baseUrl, accessToken, batch);
      unawaited(DebugLogStore.markSuccess());
      _lastActivityMs = DateTime.now().millisecondsSinceEpoch;
      unawaited(
        DebugLogStore.log('upload', 'Uploaded ${batch.length} point(s)'),
      );
    } catch (e) {
      await _outbox.write(batch);
      unawaited(
        DebugLogStore.log(
          'upload',
          'Upload failed, queued ${batch.length} point(s): $e',
        ),
      );
    }
  }

  Future<Position?> _oneShot() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: TrackingTuning.accuracyFor(
          aggressive: _pacing == 'AGGRESSIVE',
          batterySaving: _batterySaving,
        ),
        timeLimit: const Duration(seconds: 10),
      );
    } catch (e) {
      unawaited(DebugLogStore.log('position', 'One-shot fix failed: $e'));
      return null;
    }
  }

  Future<void> _syncFlushInterval(SharedPreferences prefs) async {
    final targetMs = TrackingTuning.flushIntervalFor(
      aggressive: _pacing == 'AGGRESSIVE',
      batterySaving: _batterySaving,
    );
    final currentMs = prefs.getInt('bg_current_interval_ms');
    if (currentMs == targetMs) return;
    await prefs.setInt('bg_current_interval_ms', targetMs);
    await FlutterForegroundTask.updateService(
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(targetMs),
        autoRunOnBoot: true,
        allowWakeLock: true,
      ),
    );
    unawaited(
      DebugLogStore.log(
        'pacing',
        'Flush interval -> ${targetMs}ms (pacing=$_pacing)',
      ),
    );
  }

  @override
  void onReceiveData(Object data) {
    // Pacing updates travel via SharedPreferences; picked up on the next tick.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _sub?.cancel();
    _sub = null;
    unawaited(DebugLogStore.log('lifecycle', 'Background task destroyed'));
  }

  Future<void> _uploadLocation(
    String baseUrl,
    String accessToken,
    List<Map<String, dynamic>> payload,
  ) async {
    final uri = Uri.parse('$baseUrl/api/v1/location');
    final response = await http.post(
      uri,
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $accessToken',
      },
      body: jsonEncode(payload),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Failed to upload background location batch');
    }
  }

  /// Returns (level 0–100, isCharging), with null fields when unavailable.
  Future<(int?, bool?)> _readBattery() async {
    try {
      final battery = Battery();
      final level = (await battery.batteryLevel).clamp(0, 100);
      final state = await battery.batteryState;
      final isCharging =
          state == BatteryState.charging || state == BatteryState.full;
      return (level, isCharging);
    } catch (_) {
      return (null, null);
    }
  }
}
