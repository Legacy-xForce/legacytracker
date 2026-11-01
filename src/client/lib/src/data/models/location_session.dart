import 'location_model.dart';
import '../../core/formatters.dart';

class LocationSession {
  final DateTime startAt;
  final DateTime endAt;
  final double durationSeconds;
  final double distanceMeters;
  final double avgSpeed;
  final double topSpeed;
  final List<LocationPoint> points;

  LocationSession({
    required this.startAt,
    required this.endAt,
    required this.durationSeconds,
    required this.distanceMeters,
    required this.avgSpeed,
    required this.topSpeed,
    required this.points,
  });

  Duration get duration => Duration(seconds: durationSeconds.round());

  double get avgSpeedKmh => msToKmh(avgSpeed);

  double get topSpeedKmh => msToKmh(topSpeed);

  LocationPoint? get startPoint => points.isNotEmpty ? points.first : null;

  LocationPoint? get endPoint => points.isNotEmpty ? points.last : null;

  /// Summaries (`points=false`, for the history calendar) carry no points.
  factory LocationSession.fromJson(Map<String, dynamic> json) {
    final points = (json['points'] as List<dynamic>? ?? const [])
        .map((e) => LocationPoint.fromHistoryJson(e as Map<String, dynamic>))
        .toList();
    return LocationSession(
      startAt: DateTime.parse(json['start_at'] as String),
      endAt: DateTime.parse(json['end_at'] as String),
      durationSeconds: (json['duration_seconds'] as num).toDouble(),
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      avgSpeed: (json['avg_speed'] as num).toDouble(),
      topSpeed: (json['top_speed'] as num).toDouble(),
      points: points,
    );
  }
}
