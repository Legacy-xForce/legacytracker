import 'package:latlong2/latlong.dart';

const int minCheckpointRadiusM = 10;
const int maxCheckpointRadiusM = 250;
const int maxCheckpointNameLength = 60;

/// A shared, named circle ("Home", "Office"). Anyone can see it; only its
/// creator or an admin can change it ([canEdit] is decided by the server).
class Checkpoint {
  const Checkpoint({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radiusM,
    required this.createdBy,
    required this.canEdit,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final int radiusM;
  final String createdBy;
  final bool canEdit;

  LatLng get center => LatLng(latitude, longitude);

  factory Checkpoint.fromJson(Map<String, dynamic> json) {
    return Checkpoint(
      id: json['id'] as String,
      name: json['name'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      radiusM: (json['radius_m'] as num).toInt(),
      createdBy: json['created_by'] as String,
      canEdit: json['can_edit'] as bool? ?? false,
    );
  }
}

const _distance = Distance();

/// The checkpoint a point is inside, if any. Overlaps go to the smallest
/// radius (the most specific place); ties go to the nearest center. Mirrors
/// the server's `resolveCheckpoint`.
Checkpoint? resolveCheckpoint(
  double latitude,
  double longitude,
  Iterable<Checkpoint> checkpoints,
) {
  final point = LatLng(latitude, longitude);
  Checkpoint? best;
  var bestDistance = double.infinity;
  for (final checkpoint in checkpoints) {
    final meters = _distance.as(LengthUnit.Meter, point, checkpoint.center);
    if (meters > checkpoint.radiusM) continue;
    if (best == null ||
        checkpoint.radiusM < best.radiusM ||
        (checkpoint.radiusM == best.radiusM && meters < bestDistance)) {
      best = checkpoint;
      bestDistance = meters;
    }
  }
  return best;
}
