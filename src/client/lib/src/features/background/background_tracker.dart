import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../debug/debug_log_store.dart';
import '../location/tracking_tuning.dart';
import 'background_location_handler.dart';

/// Manages the lifecycle of the background location foreground service.
///
/// Call [initialize] once before [runApp], then [start] / [stop] in response
/// to app lifecycle changes in [TrackingController].
class BackgroundTracker {
  static void initialize() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'lt_location_tracking',
        channelName: 'Location Tracking',
        channelDescription:
            'Shares your location while the app is in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(
          TrackingTuning.passiveFlushMs,
        ),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  static Future<void> start(
    String baseUrl, {
    required bool batterySavingEnabled,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bg_base_url', baseUrl);
    await prefs.setString('pacing_mode', 'PASSIVE');
    await prefs.setBool('battery_saving_enabled', batterySavingEnabled);
    await prefs.setBool('app_foreground', true);
    await prefs.setInt(
      'bg_current_interval_ms',
      passiveIntervalMs(batterySavingEnabled),
    );

    if (await FlutterForegroundTask.isRunningService) {
      await prefs.setBool('bg_service_running', true);
      await _syncServiceInterval();
      return;
    }

    // Android 13+ requires this runtime permission to display the foreground
    // service's notification; without it the OS can refuse to keep the
    // service (and its location capability) alive in the background.
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final ignoringBatteryOptimizations =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!ignoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    final result = await FlutterForegroundTask.startService(
      serviceId: 7421,
      notificationTitle: 'Legacy Tracker',
      notificationText: 'Sharing location in the background',
      callback: backgroundTaskEntryPoint,
    );
    final started = result is ServiceRequestSuccess;
    await prefs.setBool('bg_service_running', started);
    await _syncServiceInterval();
    if (started) {
      unawaited(DebugLogStore.log('lifecycle', 'Background service started'));
    } else {
      unawaited(
        DebugLogStore.log(
          'lifecycle',
          'Background service failed to start: '
              '${(result as ServiceRequestFailure).error}',
        ),
      );
    }
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
      unawaited(DebugLogStore.log('lifecycle', 'Background service stopped'));
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bg_service_running', false);
  }

  /// Called by the FCM handler (and optionally from the main isolate) when
  /// the server signals a pacing mode change.
  static Future<void> applyPacingMode(String pacing) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString('pacing_mode');
    await prefs.setString('pacing_mode', pacing);
    await _syncServiceInterval();
    if (previous != pacing) {
      unawaited(
        DebugLogStore.log('pacing', 'Pacing mode: $previous -> $pacing'),
      );
    }
  }

  /// Called on every app pause/resume so the background isolate knows
  /// whether the in-app realtime stream is already covering location
  /// updates, without touching the (already-running) foreground service.
  static Future<void> setAppForeground(bool foreground) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('app_foreground', foreground);
  }

  static Future<void> applyBatterySavingEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('battery_saving_enabled', enabled);
    await _syncServiceInterval();
    unawaited(
      DebugLogStore.log('pacing', 'Battery saving: $enabled'),
    );
  }

  static int passiveIntervalMs(bool batterySavingEnabled) =>
      TrackingTuning.flushIntervalFor(
        aggressive: false,
        batterySaving: batterySavingEnabled,
      );

  static int aggressiveIntervalMs(bool batterySavingEnabled) =>
      TrackingTuning.flushIntervalFor(
        aggressive: true,
        batterySaving: batterySavingEnabled,
      );

  static Future<void> _syncServiceInterval() async {
    if (!await FlutterForegroundTask.isRunningService) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final pacing = prefs.getString('pacing_mode') ?? 'PASSIVE';
    final batterySavingEnabled =
        prefs.getBool('battery_saving_enabled') ?? false;
    final targetMs = pacing == 'AGGRESSIVE'
        ? aggressiveIntervalMs(batterySavingEnabled)
        : passiveIntervalMs(batterySavingEnabled);
    final currentMs = prefs.getInt('bg_current_interval_ms');
    if (currentMs == targetMs) {
      return;
    }

    await prefs.setInt('bg_current_interval_ms', targetMs);
    await FlutterForegroundTask.updateService(
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(targetMs),
        autoRunOnBoot: true,
        allowWakeLock: true,
      ),
    );
  }
}
