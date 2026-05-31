import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../data/models/location_model.dart';
import '../../data/models/user_model.dart';
import '../../data/network/mock_backend.dart';
import '../location/location_repository.dart';

class TrackingController extends ChangeNotifier {
  final LocationRepository locationRepository;
  final MockBackend backend;

  TrackingController({required this.locationRepository, required this.backend}) {
    _peerSubscription = backend.peerStream.listen((data) {
      peers = data;
      notifyListeners();
    });
  }

  final UserProfile selfProfile = UserProfile(
    id: 'me',
    name: 'You',
    avatarUrl: 'https://i.pravatar.cc/150?img=66',
  );

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
    if (lastLocation != null) {
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

    _locationSubscription = locationRepository.locationStream.listen((point) async {
      lastLocation = point;
      history = [point, ...history].take(40).toList();
      selfProfile.lastLocation = point;
      selfProfile.history = history;
      await locationRepository.uploadLocation(selfProfile);
      notifyListeners();
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

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _peerSubscription?.cancel();
    locationRepository.dispose();
    super.dispose();
  }
}
