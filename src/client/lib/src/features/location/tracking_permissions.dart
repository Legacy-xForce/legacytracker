import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../updates/app_updater.dart';
import 'tracking_engine.dart';

/// Permission flow for background tracking, without nagging on every launch.
///
/// The physical-activity and battery-optimization dialogs are asked once per
/// installed build — so a fresh install or an update shows them again, but
/// relaunching the same build does not.
///
/// Notification permission is deliberately *not* requested: on Android 13+
/// the trip-recording foreground service runs fine without it — its
/// notification just isn't shown. The status card lets the user opt in.
class TrackingPermissions {
  TrackingPermissions._();

  static const _alwaysAskedAtKey = 'lt_perm_always_asked_at';
  static const _activityAskedKey = 'lt_perm_activity_asked';
  static const _batteryAskedKey = 'lt_perm_battery_asked';
  static const _askedOnBuildKey = 'lt_perm_asked_on_build';

  /// Returns whether foreground location is granted (the minimum to track).
  static Future<bool> request() async {
    if (!TrackingEngine.isSupported) return true;

    var whenInUse = await Permission.locationWhenInUse.status;
    if (!whenInUse.isGranted) {
      whenInUse = await Permission.locationWhenInUse.request();
    }
    if (!whenInUse.isGranted) return false;

    final prefs = await SharedPreferences.getInstance();

    if (Platform.isAndroid) {
      await rearmOnNewBuild(prefs);
      // Physical activity: detects driving/cycling in seconds, without GPS.
      if (!(prefs.getBool(_activityAskedKey) ?? false) &&
          !await Permission.activityRecognition.isGranted) {
        await prefs.setBool(_activityAskedKey, true);
        await Permission.activityRecognition.request();
      }
      // Some OEMs (Xiaomi, Huawei, Samsung…) otherwise block the background
      // wake-ups tracking relies on.
      if (!(prefs.getBool(_batteryAskedKey) ?? false) &&
          !await Permission.ignoreBatteryOptimizations.isGranted) {
        await prefs.setBool(_batteryAskedKey, true);
        await Permission.ignoreBatteryOptimizations.request();
      }
    }

    // "Allow all the time" lets the engine record trips while the app is
    // closed. Android 11+ sends the user to Settings for it, so ask at most
    // once a day rather than every time the app opens — and ask last, because
    // that detour is where the flow leaves the app.
    if (!await Permission.locationAlways.isGranted) {
      final lastAsked = prefs.getInt(_alwaysAskedAtKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastAsked > const Duration(days: 1).inMilliseconds) {
        await prefs.setInt(_alwaysAskedAtKey, now);
        await Permission.locationAlways.request();
      }
    }
    return true;
  }

  /// Clears the "already asked" flags when the installed build changed, so
  /// every install and update shows the dialogs once again.
  ///
  /// Without this the flags survive an update forever, and a phone that
  /// dismissed or lost one of them (an OEM resetting battery optimization on
  /// install is common) never saw the prompt again.
  @visibleForTesting
  static Future<void> rearmOnNewBuild(SharedPreferences prefs) async {
    // The native self-updater is the only place the build number is known
    // without another dependency; it reports 0 off Android.
    final build = (await AppUpdater.status())?.currentVersionCode ?? 0;
    if (build == 0 || prefs.getInt(_askedOnBuildKey) == build) return;
    await prefs.setInt(_askedOnBuildKey, build);
    await prefs.remove(_activityAskedKey);
    await prefs.remove(_batteryAskedKey);
  }

  static Future<void> requestBackgroundLocation() async {
    final status = await Permission.locationAlways.request();
    if (status.isPermanentlyDenied) await openAppSettings();
  }

  static Future<void> requestActivityRecognition() async {
    final status = await Permission.activityRecognition.request();
    if (status.isPermanentlyDenied) await openAppSettings();
  }

  static Future<void> requestIgnoreBatteryOptimizations() =>
      Permission.ignoreBatteryOptimizations.request();

  static Future<void> requestNotifications() async {
    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) await openAppSettings();
  }
}
