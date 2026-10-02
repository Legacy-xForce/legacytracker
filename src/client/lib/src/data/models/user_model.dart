import 'location_model.dart';

class UserProfile {
  final String id;
  String name;
  String avatarUrl;
  String role;
  bool locationTrackingPaused;
  bool missingPermissions;
  bool batterySavingEnabled;
  int? batteryLevel;
  bool? isCharging;
  LocationPoint? lastLocation;
  List<LocationPoint> history;

  /// Server-reported time this user's device last reached the server (trip
  /// upload, live point, on-demand ping or parked heartbeat).
  DateTime? lastSeenAt;

  UserProfile({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    this.role = 'user',
    this.locationTrackingPaused = false,
    this.missingPermissions = false,
    this.batterySavingEnabled = false,
    this.batteryLevel,
    this.isCharging,
    this.lastLocation,
    this.lastSeenAt,
    List<LocationPoint>? history,
  }) : history = history ?? [];

  bool get hasAnyStatus =>
      locationTrackingPaused || missingPermissions || batterySavingEnabled;

  /// Whether we haven't heard from this user's device for long enough that
  /// their marker should be greyed out. Parked devices check in about every
  /// half hour (longer in deep Doze) and answer a live ping within seconds
  /// of someone opening the map, so silence beyond this means the phone is
  /// off, offline or not sharing.
  static const staleThreshold = Duration(minutes: 90);

  bool get isStale {
    final seen = lastSeenAt;
    if (seen == null) return true;
    return DateTime.now().difference(seen) > staleThreshold;
  }
}
