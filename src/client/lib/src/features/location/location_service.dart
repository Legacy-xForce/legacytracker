import 'dart:async';

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
  final LocationSettings _settings = const LocationSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 1,
  );

  Stream<LocationPoint>? _locationStream;

  @override
  Future<bool> requestPermission() async {
    final status = await Permission.locationWhenInUse.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      return false;
    }
    return true;
  }

  @override
  Stream<LocationPoint> get locationStream {
    _locationStream ??=
        Geolocator.getPositionStream(locationSettings: _settings).map(
          (position) => LocationPoint(
            latitude: position.latitude,
            longitude: position.longitude,
            speed: position.speed,
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
