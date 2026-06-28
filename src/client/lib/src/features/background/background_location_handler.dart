import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Entry point called by flutter_foreground_task in its own isolate.
@pragma('vm:entry-point')
void backgroundTaskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(BackgroundLocationHandler());
}

class BackgroundLocationHandler extends TaskHandler {
  static const _passiveIntervalMs = 120000; // 2 minutes
  static const _aggressiveIntervalMs = 5000; // 5 seconds

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

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: isAggressive ? LocationAccuracy.high : LocationAccuracy.low,
        timeLimit: const Duration(seconds: 15),
      );
      await _uploadLocation(baseUrl, accessToken, position);
    } catch (_) {
      // Silently ignore — GPS or network unavailable in background.
    }

    // Adjust the repeat interval to match the current pacing mode.
    final targetMs = isAggressive ? _aggressiveIntervalMs : _passiveIntervalMs;
    final currentMs = prefs.getInt('bg_current_interval_ms') ?? _passiveIntervalMs;
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
    Position position,
  ) async {
    final battery = await _readBattery();
    final uri = Uri.parse('$baseUrl/api/v1/location');
    await http.post(
      uri,
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $accessToken',
      },
      body: jsonEncode([
        {
          'coords': {
            'latitude': position.latitude,
            'longitude': position.longitude,
            'speed': position.speed >= 0 ? position.speed : 0.0,
            'heading': position.heading.isFinite ? position.heading : null,
          },
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'battery_level': ?battery.$1,
          'is_charging': ?battery.$2,
        }
      ]),
    );
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
