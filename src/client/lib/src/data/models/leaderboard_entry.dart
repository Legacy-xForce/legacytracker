/// One person's travel over the leaderboard's period.
class LeaderboardEntry {
  const LeaderboardEntry({
    required this.userId,
    required this.name,
    required this.rank,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.avgSpeed,
    required this.topSpeed,
    required this.tripCount,
  });

  final String userId;
  final String name;

  /// Equal distances share a rank.
  final int rank;
  final double distanceMeters;

  /// Time spent on trips.
  final double durationSeconds;
  final double avgSpeed;
  final double topSpeed;
  final int tripCount;

  Duration get duration => Duration(seconds: durationSeconds.round());

  double get avgSpeedKmh => avgSpeed * 3.6;

  double get topSpeedKmh => topSpeed * 3.6;

  static LeaderboardEntry? fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    if (userId is! String || userId.isEmpty) return null;
    final name = json['username'];
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return LeaderboardEntry(
      userId: userId,
      name: name is String && name.isNotEmpty ? name : userId,
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      distanceMeters: number('distance_meters'),
      durationSeconds: number('duration_seconds'),
      avgSpeed: number('avg_speed'),
      topSpeed: number('top_speed'),
      tripCount: (json['trip_count'] as num?)?.toInt() ?? 0,
    );
  }
}
