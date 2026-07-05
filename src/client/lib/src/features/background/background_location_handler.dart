import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/location_model.dart';
import '../location/location_outbox.dart';
import '../location/location_payload.dart';

// Entry point called by flutter_foreground_task in its own isolate.
@pragma('vm:entry-point')
void backgroundTaskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(BackgroundLocationHandler());
}

class BackgroundLocationHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString('auth_access_token');
    final baseUrl = prefs.getString('bg_base_url');
    if (accessToken == null || baseUrl == null) return;

    final pacing = prefs.getString('pacing_mode') ?? 'PASSIVE';
    final isAggressive = pacing == 'AGGRESSIVE';
    final batterySavingEnabled =
        prefs.getBool('battery_saving_enabled') ?? false;
    final outbox = LocationOutbox();
    final queued = await outbox.drain();

    Map<String, dynamic>? currentPayload;
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: batterySavingEnabled
            ? LocationAccuracy.low
            : isAggressive
            ? LocationAccuracy.high
            : LocationAccuracy.low,
        timeLimit: const Duration(seconds: 15),
      );
      final battery = await _readBattery();
      currentPayload = buildLocationPayload(
        LocationPoint(
          latitude: position.latitude,
          longitude: position.longitude,
          speed: position.speed >= 0 ? position.speed : 0.0,
          heading: position.heading.isFinite ? position.heading : null,
          timestamp: DateTime.now(),
        ),
        batteryLevel: battery.$1,
        isCharging: battery.$2,
      );
    } catch (_) {
      // GPS can be unavailable in background; queued points may still flush.
    }

    final batch = [...queued];
    if (currentPayload != null) {
      batch.add(currentPayload);
    }
    if (batch.isNotEmpty) {
      try {
        await _uploadLocation(baseUrl, accessToken, batch);
      } catch (_) {
        await outbox.write(batch);
      }
    }

    // Adjust the repeat interval to match the current pacing mode.
    final targetMs = isAggressive
        ? _aggressiveIntervalMs(batterySavingEnabled)
        : _passiveIntervalMs(batterySavingEnabled);
    final currentMs =
        prefs.getInt('bg_current_interval_ms') ??
        _passiveIntervalMs(batterySavingEnabled);
    if (currentMs != targetMs) {
      await prefs.setInt('bg_current_interval_ms', targetMs);
      await FlutterForegroundTask.updateService(
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(targetMs),
          allowWakeLock: true,
        ),
      );
    }
  }

  @override
  void onReceiveData(Object data) {
    // Pacing updates from the main isolate are written directly to
    // SharedPreferences by BackgroundTracker; the change is picked up on the
    // next onRepeatEvent tick, so no explicit action is needed here.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

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

  int _passiveIntervalMs(bool batterySavingEnabled) =>
      batterySavingEnabled ? 300000 : 120000;

  int _aggressiveIntervalMs(bool batterySavingEnabled) =>
      batterySavingEnabled ? 15000 : 5000;
}
