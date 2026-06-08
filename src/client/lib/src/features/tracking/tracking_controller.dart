import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../data/models/location_model.dart';
import '../../data/models/user_model.dart';
import '../../data/network/backend.dart';
import '../location/location_repository.dart';

class TrackingController extends ChangeNotifier {
  final LocationRepository locationRepository;
  final Backend backend;

  TrackingController({
    required this.locationRepository,
    required this.backend,
    UserProfile? initialProfile,
  }) : selfProfile = initialProfile ?? UserProfile(
          id: 'me',
          name: 'You',
          avatarUrl: 'https://avatars.githubusercontent.com/u/38632219?v=4',
        ) {
    _peerSubscription = backend.peerStream.listen((data) {
      peers = data;
      notifyListeners();
    });
  }

  final UserProfile selfProfile;

  bool isTracking = false;
  bool permissionGranted = false;
  LocationPoint? lastLocation;
  List<LocationPoint> history = [];
  List<UserProfile> peers = [];

  StreamSubscription<List<UserProfile>>? _peerSubscription;
  StreamSubscription<LocationPoint>? _locationSubscription;

  String get speedLabel {
    final speed = lastLocation?.speed ?? 0.0;
    return '${speed.toStringAsFixed(1)} m/s';
  }

  bool get isMoving {
    return lastLocation?.speed != null && (lastLocation?.speed ?? 0) >= 1.0;
  }

  LatLng get mapCenter {
    if (lastLocation != null &&
        lastLocation!.latitude.isFinite &&
        lastLocation!.longitude.isFinite) {
      return LatLng(lastLocation!.latitude, lastLocation!.longitude);
    }
    return const LatLng(37.7749, -122.4194);
  }

  Future<void> startTracking() async {
    if (isTracking) {
      return;
    }

    permissionGranted = await locationRepository.requestPermission();
    if (!permissionGranted) {
      notifyListeners();
      return;
    }

    await backend.initialize();

    _locationSubscription = locationRepository.locationStream.listen((point) {
      if (!point.latitude.isFinite || !point.longitude.isFinite) {
        return;
      }

      lastLocation = point;
      history = [point, ...history].take(40).toList();
      selfProfile.lastLocation = point;
      selfProfile.history = history;
      notifyListeners();
      unawaited(_uploadLocation(selfProfile));
    });

    isTracking = true;
    notifyListeners();
  }

  Future<void> stopTracking() async {
    if (!isTracking) {
      return;
    }

    await _locationSubscription?.cancel();
    _locationSubscription = null;
    isTracking = false;
    notifyListeners();
  }

  void updateProfile({required String name, required String avatarUrl}) {
    selfProfile.name = name;
    selfProfile.avatarUrl = avatarUrl;
    notifyListeners();
  }

  void setSelfProfile(UserProfile profile) {
    selfProfile.name = profile.name;
    selfProfile.avatarUrl = profile.avatarUrl;
    selfProfile.role = profile.role;
    notifyListeners();
  }

  Future<void> _uploadLocation(UserProfile profile) async {
    try {
      await locationRepository.uploadLocation(profile);
    } catch (_) {
      // Ignore upload failures here so live tracking stays responsive.
    }
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _peerSubscription?.cancel();
    locationRepository.dispose();
    backend.dispose();
    super.dispose();
  }
}
