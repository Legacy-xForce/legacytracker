import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/models/location_model.dart';

/// Where the native engine is in its cycle.
///
/// [stationary] is the normal state: no GPS, only cheap OS triggers armed.
/// [moving] means a trip is being recorded with GPS.
enum TrackingMode { off, stationary, moving }

/// A raw fix the engine saw while the app is on screen.
class TrackingFix {
  const TrackingFix({
    required this.latitude,
    required this.longitude,
    required this.time,
    this.accuracy,
    this.speed,
    this.heading,
  });

  factory TrackingFix.fromMap(Map<String, dynamic> map) {
    return TrackingFix(
      latitude: (map['lat'] as num).toDouble(),
      longitude: (map['lon'] as num).toDouble(),
      time: DateTime.fromMillisecondsSinceEpoch((map['time'] as num).toInt()),
      accuracy: (map['accuracy'] as num?)?.toDouble(),
      speed: (map['speed'] as num?)?.toDouble(),
      heading: (map['heading'] as num?)?.toDouble(),
    );
  }

  final double latitude;
  final double longitude;
  final DateTime time;
  final double? accuracy;
  final double? speed;
  final double? heading;

  LocationPoint toLocationPoint() => LocationPoint(
    latitude: latitude,
    longitude: longitude,
    speed: speed ?? 0.0,
    heading: heading,
    timestamp: time,
  );
}

/// Snapshot of the engine for status UI and diagnostics.
class TrackingStatus {
  const TrackingStatus({
    this.mode = TrackingMode.off,
    this.configured = false,
    this.authFailed = false,
    this.live = false,
    this.lowPower = false,
    this.pending = 0,
    this.lastUploadAt,
    this.lastUploadError,
    this.lastFixAt,
    this.stationarySince,
    this.preciseLocation = true,
    this.backgroundLocation = true,
    this.activityRecognition = true,
    this.batteryOptimizationIgnored = true,
    this.notificationsEnabled = false,
  });

  factory TrackingStatus.fromMap(Map<String, dynamic> map) {
    DateTime? time(String key) {
      final value = map[key] as num?;
      return value == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }

    return TrackingStatus(
      mode: TrackingMode.values.firstWhere(
        (m) => m.name == map['mode'],
        orElse: () => TrackingMode.off,
      ),
      configured: map['configured'] as bool? ?? false,
      authFailed: map['authFailed'] as bool? ?? false,
      live: map['live'] as bool? ?? false,
      lowPower: map['lowPower'] as bool? ?? false,
      pending: (map['pending'] as num?)?.toInt() ?? 0,
      lastUploadAt: time('lastUploadAt'),
      lastUploadError: map['lastUploadError'] as String?,
      lastFixAt: time('lastFixAt'),
      stationarySince: time('stationarySince'),
      preciseLocation: map['preciseLocation'] as bool? ?? true,
      backgroundLocation: map['backgroundLocation'] as bool? ?? true,
      activityRecognition: map['activityRecognition'] as bool? ?? true,
      batteryOptimizationIgnored:
          map['batteryOptimizationIgnored'] as bool? ?? true,
      notificationsEnabled: map['notificationsEnabled'] as bool? ?? false,
    );
  }

  final TrackingMode mode;
  final bool configured;
  final bool authFailed;
  final bool live;
  final bool lowPower;
  final int pending;
  final DateTime? lastUploadAt;
  final String? lastUploadError;
  final DateTime? lastFixAt;
  final DateTime? stationarySince;
  final bool preciseLocation;
  final bool backgroundLocation;
  final bool activityRecognition;
  final bool batteryOptimizationIgnored;
  final bool notificationsEnabled;
}

class TrackingLogEntry {
  const TrackingLogEntry({
    required this.time,
    required this.category,
    required this.message,
  });

  final DateTime time;
  final String category;
  final String message;
}

/// Dart side of the native tracking engine
/// (android/.../tracking/TrackingEngine.kt, ios/Runner/TrackingEngine.swift).
///
/// The engine records, stores and uploads entirely in native code, with no
/// Flutter engine running, so tracking continues while the app is closed.
/// Dart only configures it, reads its status, and receives fixes while the
/// UI is on screen. Every call is a no-op where there is no native side
/// (tests, desktop, web).
class TrackingEngine {
  TrackingEngine._();

  static const MethodChannel _methods = MethodChannel('legacytracker/tracking');
  static const EventChannel _events = EventChannel(
    'legacytracker/tracking/events',
  );

  static Stream<Map<String, dynamic>>? _eventStream;

  /// Lets tests exercise the channel calls on the host platform.
  @visibleForTesting
  static bool? debugSupportedOverride;

  static bool get isSupported =>
      debugSupportedOverride ??
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  /// Engine events: `location`, `state`, `upload`, `auth_required`.
  static Stream<Map<String, dynamic>> get events {
    if (!isSupported) return const Stream.empty();
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map((event) => Map<String, dynamic>.from(event as Map))
        .asBroadcastStream();
  }

  static Future<void> configure({
    required String baseUrl,
    required String authHeader,
    required String userId,
    bool batterySaver = false,
  }) => _invoke<void>('configure', {
    'baseUrl': baseUrl,
    'authHeader': authHeader,
    'userId': userId,
    'batterySaver': batterySaver,
  });

  static Future<void> start() => _invoke<void>('start');

  /// Disarms everything. [clearData] (sign-out) first attempts a final upload,
  /// then wipes the local queue and the upload credentials.
  static Future<void> stop({bool clearData = false}) =>
      _invoke<void>('stop', {'clearData': clearData});

  /// While visible the engine streams fixes to [events] and uploads promptly.
  static Future<void> setAppVisible(bool visible) =>
      _invoke<void>('setAppVisible', {'visible': visible});

  static Future<void> flush() => _invoke<void>('flush');

  static Future<TrackingStatus> status() async {
    final map = await _invoke<Map<Object?, Object?>>('status');
    return map == null
        ? const TrackingStatus()
        : TrackingStatus.fromMap(Map<String, dynamic>.from(map));
  }

  static Future<List<TrackingLogEntry>> logs({int limit = 300}) async {
    final list = await _invoke<List<Object?>>('logs', {'limit': limit});
    if (list == null) return const [];
    return list.whereType<Map<Object?, Object?>>().map((raw) {
      final entry = Map<String, dynamic>.from(raw);
      return TrackingLogEntry(
        time: DateTime.fromMillisecondsSinceEpoch(
          (entry['ts'] as num).toInt(),
        ),
        category: entry['cat'] as String? ?? '',
        message: entry['msg'] as String? ?? '',
      );
    }).toList();
  }

  static Future<void> clearLogs() => _invoke<void>('clearLogs');

  /// Adds a line to the engine's activity log (shown in the debug screen).
  static Future<void> log(String category, String message) =>
      _invoke<void>('log', {'category': category, 'message': message});

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
