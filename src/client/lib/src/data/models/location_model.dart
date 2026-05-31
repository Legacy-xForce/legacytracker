class LocationPoint {
  final double latitude;
  final double longitude;
  final double speed;
  final double? heading;
  final DateTime timestamp;

  LocationPoint({
    required this.latitude,
    required this.longitude,
    this.speed = 0.0,
    this.heading,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isMoving => speed >= 1.0;

  bool get hasHeading => heading != null && heading!.isFinite;
}
