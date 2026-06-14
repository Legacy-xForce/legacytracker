import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_location_handler.dart';

/// Manages the lifecycle of the background location foreground service.
///
/// Call [initialize] once before [runApp], then [start] / [stop] in response
/// to app lifecycle changes in [TrackingController].
class BackgroundTracker {
  static const _passiveIntervalMs = 120000;

  static void initialize() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'lt_location_tracking',
        channelName: 'Location Tracking',
        channelDescription: 'Shares your location while the app is in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(_passiveIntervalMs),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  static Future<void> start(String baseUrl) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bg_base_url', baseUrl);
    await prefs.setString('pacing_mode', 'PASSIVE');
    await prefs.setInt('bg_current_interval_ms', _passiveIntervalMs);

    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      serviceId: 7421,
      notificationTitle: 'Legacy Tracker',
      notificationText: 'Sharing location in the background',
      callback: backgroundTaskEntryPoint,
    );
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Called by the FCM handler (and optionally from the main isolate) when
  /// the server signals a pacing mode change.
  static Future<void> applyPacingMode(String pacing) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pacing_mode', pacing);
    // The background handler reads this on its next tick and self-adjusts the
    // interval via FlutterForegroundTask.updateService.
  }
}
