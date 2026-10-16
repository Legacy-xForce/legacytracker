import 'location_model.dart';
import 'tracking_issue.dart';

class UserProfile {
  final String id;
  String name;
  String avatarUrl;
  String role;
  bool locationTrackingPaused;
  bool missingPermissions;
  bool batterySavingEnabled;

  /// False when this user has switched off sharing their location with us:
  /// they stay in the roster, but nothing about where they are comes through.
  bool sharesWithMe;
  int? batteryLevel;
  bool? isCharging;

  /// Phone settings this user's device last reported as blocking location
  /// updates; empty when nothing is wrong (or nothing was reported yet).
  List<TrackingIssue> trackingIssues;
  LocationPoint? lastLocation;
  List<LocationPoint> history;

  /// Server-reported time this user's device last reached the server (trip
  /// upload, live point, on-demand ping or parked heartbeat).
  DateTime? lastSeenAt;

  /// When this user arrived where they are now — the start of the "Here for"
  /// counter. The newest fix can't serve as that: a parked phone still
  /// reports a fresh fix every few seconds while someone watches.
  DateTime? hereSince;

  /// Set on our own profile from the tracking engine (a trip is being
  /// recorded); peers are judged by their latest speed instead.
  bool? travelling;

  bool get isTravelling => travelling ?? (lastLocation?.isMoving ?? false);

  UserProfile({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    this.role = 'user',
    this.locationTrackingPaused = false,
    this.missingPermissions = false,
    this.batterySavingEnabled = false,
    this.sharesWithMe = true,
    this.batteryLevel,
    this.isCharging,
    this.trackingIssues = const [],
    this.lastLocation,
    this.lastSeenAt,
    this.hereSince,
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
