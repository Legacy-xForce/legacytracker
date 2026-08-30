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

  /// Server-reported time this user last sent any location (move, foreground,
  /// or stationary heartbeat). Paired with the ≤5-min heartbeat, a genuinely
  /// online user keeps this fresh even while parked.
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

  /// Whether this user's last report is old enough that their marker should
  /// be treated as stale (greyed out).
  static const staleThreshold = Duration(minutes: 15);

  bool get isStale {
    final seen = lastSeenAt;
    if (seen == null) return true;
    return DateTime.now().difference(seen) > staleThreshold;
  }
}
