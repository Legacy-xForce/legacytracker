import 'dart:async';
import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/models/location_model.dart';
import '../../mocks/mock_location_provider.dart';

abstract class LocationService {
  Future<bool> requestPermission();
  Stream<LocationPoint> get locationStream;
  Future<void> dispose();
}

class GeolocatorLocationService implements LocationService {
  LocationSettings get _settings {
    if (Platform.isIOS || Platform.isMacOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        activityType: ActivityType.other,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    );
  }

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
          ),
        );
    return _locationStream!;
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
  Future<void> dispose() async {
    await _provider.dispose();
  }
}
