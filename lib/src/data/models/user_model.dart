import 'location_model.dart';

class UserProfile {
  final String id;
  String name;
  String avatarUrl;
  LocationPoint? lastLocation;
  List<LocationPoint> history;

  UserProfile({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    this.lastLocation,
    List<LocationPoint>? history,
  }) : history = history ?? [];
}
