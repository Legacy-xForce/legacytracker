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

  factory LocationPoint.fromHistoryJson(Map<String, dynamic> json) {
    return LocationPoint(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
      heading: (json['heading'] as num?)?.toDouble(),
      timestamp: DateTime.parse(json['recorded_at'] as String),
    );
  }
}
