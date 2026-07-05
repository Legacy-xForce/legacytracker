import '../../data/models/location_model.dart';

Map<String, dynamic> buildLocationPayload(
  LocationPoint point, {
  int? batteryLevel,
  bool? isCharging,
}) {
  final payload = <String, dynamic>{
    'coords': {
      'latitude': point.latitude,
      'longitude': point.longitude,
      'speed': point.speed >= 0 ? point.speed : 0.0,
      'heading': point.heading,
    },
    'timestamp': point.timestamp.toUtc().toIso8601String(),
  };

  if (batteryLevel != null) {
    payload['battery_level'] = batteryLevel;
  }
  if (isCharging != null) {
    payload['is_charging'] = isCharging;
  }

  return payload;
}

Map<String, dynamic> buildRealtimeLocationPayload(
  LocationPoint point, {
  int? batteryLevel,
  bool? isCharging,
}) {
  return {
    'type': 'location',
    ...buildLocationPayload(
      point,
      batteryLevel: batteryLevel,
      isCharging: isCharging,
    ),
  };
}
