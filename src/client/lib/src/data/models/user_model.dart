import 'location_model.dart';

class UserProfile {
  final String id;
  String name;
  String avatarUrl;
  String role;
  LocationPoint? lastLocation;
  List<LocationPoint> history;

  UserProfile({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    this.role = 'user',
    this.lastLocation,
    List<LocationPoint>? history,
  }) : history = history ?? [];
}
