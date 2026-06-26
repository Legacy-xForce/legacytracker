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
  LocationPoint? lastLocation;
  List<LocationPoint> history;

  UserProfile({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    this.role = 'user',
    this.locationTrackingPaused = false,
    this.missingPermissions = false,
    this.batterySavingEnabled = false,
    this.batteryLevel,
    this.lastLocation,
    List<LocationPoint>? history,
  }) : history = history ?? [];

  bool get hasAnyStatus =>
      locationTrackingPaused || missingPermissions || batterySavingEnabled;
}
