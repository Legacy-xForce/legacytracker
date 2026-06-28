import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../data/models/location_model.dart';
import '../../data/models/user_model.dart';
import '../../data/network/backend.dart';
import '../background/background_tracker.dart';
import '../location/battery_service.dart';
import '../location/location_repository.dart';

class TrackingController extends ChangeNotifier with WidgetsBindingObserver {
  TrackingController({
    required this.locationRepository,
    required this.backend,
    required this.baseUrl,
    BatteryService? batteryService,
    UserProfile? initialProfile,
  })  : batteryService = batteryService ?? BatteryService(),
        selfProfile = initialProfile ??
            UserProfile(
              id: 'me',
              name: 'You',
              avatarUrl: 'https://avatars.githubusercontent.com/u/38632219?v=4',
            ) {
    WidgetsBinding.instance.addObserver(this);
    _peerSubscription = backend.peerStream.listen((data) {
      peers = data;
      notifyListeners();
    });
  }

  final LocationRepository locationRepository;
  final Backend backend;
  final String baseUrl;
  final BatteryService batteryService;
  final UserProfile selfProfile;

  bool isTracking = false;
  bool permissionGranted = false;
  LocationPoint? lastLocation;
  List<LocationPoint> history = [];
  List<UserProfile> peers = [];

  StreamSubscription<List<UserProfile>>? _peerSubscription;
  StreamSubscription<LocationPoint>? _locationSubscription;
  StreamSubscription<void>? _batterySubscription;
  Timer? _batteryRefreshTimer;

  String get speedLabel {
    final speed = lastLocation?.speed ?? 0.0;
    return '${speed.toStringAsFixed(1)} m/s';
  }

  bool get isMoving =>
      lastLocation?.speed != null && (lastLocation?.speed ?? 0) >= 1.0;

  LatLng get mapCenter {
    if (lastLocation != null &&
        lastLocation!.latitude.isFinite &&
        lastLocation!.longitude.isFinite) {
      return LatLng(lastLocation!.latitude, lastLocation!.longitude);
    }
    return const LatLng(37.7749, -122.4194);
  }

  // ── App lifecycle ─────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (isTracking) _switchToBackground();
        break;
      case AppLifecycleState.resumed:
        if (isTracking) _switchToForeground();
        break;
      default:
        break;
    }
  }

  void _switchToBackground() {
    _locationSubscription?.cancel();
    _locationSubscription = null;
    _stopBatteryMonitoring();
    BackgroundTracker.start(baseUrl);
  }

  void _switchToForeground() {
    BackgroundTracker.stop();
    _startLocationStream();
    _startBatteryMonitoring();
  }

  // ── Tracking ──────────────────────────────────────────────────────────────

  Future<void> startTracking() async {
    if (isTracking) return;

    permissionGranted = await locationRepository.requestPermission();
    if (!permissionGranted) {
      notifyListeners();
      return;
    }

    _startLocationStream();
    _startBatteryMonitoring();
    isTracking = true;
    notifyListeners();

    // Backend connection is best-effort; local tracking works without it.
    backend.initialize().catchError((_) {});
  }

  void _startLocationStream() {
    _locationSubscription?.cancel();
    _locationSubscription =
        locationRepository.locationStream.listen((point) {
      if (!point.latitude.isFinite || !point.longitude.isFinite) return;

      lastLocation = point;
      history = [point, ...history].take(40).toList();
      selfProfile.lastLocation = point;
      selfProfile.history = history;
      notifyListeners();

      // Foreground: send realtime over the open WebSocket, tagging the device's
      // current power state so peers can render the battery badge.
      backend.sendLocationRealtime(
        point,
        batteryLevel: selfProfile.batteryLevel,
        isCharging: selfProfile.isCharging,
      );
    });
  }

  // Keep [selfProfile]'s battery fields fresh: react to charging-state changes
  // immediately and re-poll the level periodically (the platform doesn't push
  // level changes). The next location send carries the updated values.
  void _startBatteryMonitoring() {
    _refreshBattery();
    _batterySubscription?.cancel();
    _batterySubscription =
        batteryService.onChanged.listen((_) => _refreshBattery());
    _batteryRefreshTimer?.cancel();
    _batteryRefreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshBattery(),
    );
  }

  void _stopBatteryMonitoring() {
    _batterySubscription?.cancel();
    _batterySubscription = null;
    _batteryRefreshTimer?.cancel();
    _batteryRefreshTimer = null;
  }

  Future<void> _refreshBattery() async {
    final snapshot = await batteryService.read();
    if (snapshot.level == null && snapshot.isCharging == null) return;
    selfProfile.batteryLevel = snapshot.level;
    selfProfile.isCharging = snapshot.isCharging;
    notifyListeners();
  }

  Future<void> stopTracking() async {
    if (!isTracking) return;

    await _locationSubscription?.cancel();
    _locationSubscription = null;
    _stopBatteryMonitoring();
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationSubscription?.cancel();
    _peerSubscription?.cancel();
    _stopBatteryMonitoring();
    locationRepository.dispose();
    backend.dispose();
    BackgroundTracker.stop();
    super.dispose();
  }
}
