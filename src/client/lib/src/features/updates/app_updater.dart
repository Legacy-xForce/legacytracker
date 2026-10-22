import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of the Android self-updater (android/.../updates/AppUpdater.kt).
///
/// Builds distributed outside the Play Store update themselves: the native
/// side asks the server for the current release, downloads newer APKs and
/// installs them while the app is in the background. Dart only points it at
/// the server and shows its state. Every call is a no-op off Android.
class AppUpdater {
  AppUpdater._();

  static const MethodChannel _methods = MethodChannel('legacytracker/updates');
  static const EventChannel _events = EventChannel(
    'legacytracker/updates/events',
  );

  static Stream<AppUpdateStatus>? _statusStream;

  /// Lets tests exercise the channel calls on the host platform.
  @visibleForTesting
  static bool? debugSupportedOverride;

  static bool get isSupported =>
      debugSupportedOverride ?? (!kIsWeb && Platform.isAndroid);

  /// Status changes: checks, download progress, install results.
  static Stream<AppUpdateStatus> get statusChanges {
    if (!isSupported) return const Stream.empty();
    return _statusStream ??= _events
        .receiveBroadcastStream()
        .map(
          (event) =>
              AppUpdateStatus.fromMap(Map<String, dynamic>.from(event as Map)),
        )
        .asBroadcastStream();
  }

  /// Call at every app start: schedules background checks against [baseUrl].
  static Future<void> configure(String baseUrl) =>
      _invoke<void>('configure', {'baseUrl': baseUrl});

  static Future<AppUpdateStatus?> status() => _status('status');

  /// Asks the server now. Failures are reported in [AppUpdateStatus.lastError].
  static Future<AppUpdateStatus?> check() => _status('check');

  /// Downloads and installs the available update. The app closes while it
  /// installs; Android may ask the user to confirm first.
  static Future<AppUpdateStatus?> install() => _status('install');

  /// The system screen where the user lets this app install updates.
  static Future<void> openInstallSettings() =>
      _invoke<void>('openInstallSettings');

  static Future<AppUpdateStatus?> _status(String method) async {
    final map = await _invoke<Map<Object?, Object?>>(method);
    return map == null
        ? null
        : AppUpdateStatus.fromMap(Map<String, dynamic>.from(map));
  }

  static Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (!isSupported) return null;
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }
}

class AppUpdateStatus {
  const AppUpdateStatus({
    required this.currentVersionName,
    required this.currentVersionCode,
    this.availableVersionName,
    this.availableVersionCode,
    this.minSupportedCode = 0,
    this.notes,
    this.downloaded = false,
    this.failed = false,
    this.progress,
    this.installPermission = false,
    this.silentInstall = false,
    this.automatic = true,
    this.lastCheckAt,
    this.lastError,
  });

  factory AppUpdateStatus.fromMap(Map<String, dynamic> map) {
    DateTime? time(String key) {
      final value = map[key];
      return value is num
          ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
          : null;
    }

    return AppUpdateStatus(
      currentVersionName: map['currentVersionName'] as String? ?? '',
      currentVersionCode: (map['currentVersionCode'] as num?)?.toInt() ?? 0,
      availableVersionName: map['availableVersionName'] as String?,
      availableVersionCode: (map['availableVersionCode'] as num?)?.toInt(),
      minSupportedCode: (map['minSupportedCode'] as num?)?.toInt() ?? 0,
      notes: map['notes'] as String?,
      downloaded: map['downloaded'] as bool? ?? false,
      failed: map['failed'] as bool? ?? false,
      progress: (map['progress'] as num?)?.toDouble(),
      installPermission: map['installPermission'] as bool? ?? false,
      silentInstall: map['silentInstall'] as bool? ?? false,
      automatic: map['automatic'] as bool? ?? true,
      lastCheckAt: time('lastCheckAt'),
      lastError: map['lastError'] as String?,
    );
  }

  final String currentVersionName;
  final int currentVersionCode;
  final String? availableVersionName;
  final int? availableVersionCode;

  /// The oldest build the server still supports; older ones must update.
  final int minSupportedCode;
  final String? notes;

  /// The available update is downloaded and verified.
  final bool downloaded;

  /// Installing the available update failed for good (e.g. signed with a
  /// different key); it won't be retried automatically.
  final bool failed;

  /// Download progress 0–1 while downloading.
  final double? progress;

  /// The user allowed this app to install apps ("Install unknown apps").
  final bool installPermission;

  /// Updates install without any prompt (Android 12+ with [installPermission]).
  final bool silentInstall;

  /// False in debug builds, which only update when asked.
  final bool automatic;
  final DateTime? lastCheckAt;
  final String? lastError;

  bool get updateAvailable => availableVersionCode != null;
  bool get updateRequired => currentVersionCode < minSupportedCode;
  bool get downloading => progress != null;
}
