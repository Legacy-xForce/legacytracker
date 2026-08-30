import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/models/location_model.dart';
import '../../mocks/mock_location_provider.dart';
import 'tracking_tuning.dart';

abstract class LocationService {
  Future<bool> requestPermission();
  Stream<LocationPoint> get locationStream;
  Future<LocationPoint?> getCurrentLocation();
  void setBatterySavingEnabled(bool enabled);
  Future<void> dispose();
}

class GeolocatorLocationService implements LocationService {
  bool _batterySavingEnabled = false;

  // Foreground (app visible) is treated as AGGRESSIVE unless the user opted
  // into battery saving — someone is likely watching the live map. The
  // per-point movement gate in TrackingController is what actually bounds WS
  // traffic; distanceFilter/accuracy here just keep the radio honest.
  LocationSettings get _settings => TrackingTuning.settingsFor(
        aggressive: !_batterySavingEnabled,
        batterySaving: _batterySavingEnabled,
      );

  Stream<LocationPoint>? _locationStream;

  @override
  Future<bool> requestPermission() async {
    final whenInUse = await Permission.locationWhenInUse.request();
    if (whenInUse.isDenied || whenInUse.isPermanentlyDenied) {
      return false;
    }
    // Upgrade to "always" for background tracking. User may deny — that is
    // fine; foreground tracking still works and the background service simply
    // won't be able to obtain a position on iOS without this grant.
    await Permission.locationAlways.request();
    return true;
  }

  @override
  Stream<LocationPoint> get locationStream {
    _locationStream ??=
        Geolocator.getPositionStream(locationSettings: _settings).map(
          (position) => LocationPoint(
            latitude: position.latitude,
            longitude: position.longitude,
            // On iOS, speed is -1.0 when unavailable; clamp to zero.
            speed: position.speed < 0 ? 0.0 : position.speed,
            heading: position.heading.isFinite ? position.heading : null,
            timestamp: position.timestamp,
          ),
        );
    return _locationStream!;
  }

  @override
  Future<LocationPoint?> getCurrentLocation() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      final position =
          last ??
          await Geolocator.getCurrentPosition(
            desiredAccuracy: _batterySavingEnabled
                ? LocationAccuracy.low
                : LocationAccuracy.best,
            timeLimit: const Duration(seconds: 10),
          );
      return LocationPoint(
        latitude: position.latitude,
        longitude: position.longitude,
        speed: position.speed < 0 ? 0.0 : position.speed,
        heading: position.heading.isFinite ? position.heading : null,
        timestamp: position.timestamp,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void setBatterySavingEnabled(bool enabled) {
    if (_batterySavingEnabled == enabled) {
      return;
    }
    _batterySavingEnabled = enabled;
    _locationStream = null;
  }

  @override
  Future<void> dispose() async {
    // Geolocator stream is managed by the package and does not require manual cleanup.
  }
}

class MockLocationService implements LocationService {
  final MockLocationProvider _provider = MockLocationProvider();

  @override
  Future<bool> requestPermission() async {
    return true;
  }

  @override
  Stream<LocationPoint> get locationStream => _provider.locationStream;

  @override
  Future<LocationPoint?> getCurrentLocation() async => _provider.current;

  @override
  void setBatterySavingEnabled(bool enabled) {}

  @override
  Future<void> dispose() async {
    await _provider.dispose();
  }
}
