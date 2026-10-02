import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../../data/models/location_model.dart';
import '../../data/models/user_model.dart';
import '../../data/network/backend.dart';
import '../../data/network/device_service.dart';
import '../location/battery_service.dart';
import '../location/tracking_engine.dart';
import '../location/tracking_permissions.dart';

/// UI-side view of location sharing.
///
/// Recording and uploading happen in the native [TrackingEngine], which keeps
/// running when this controller (and the whole Flutter UI) is gone. This
/// controller configures the engine, mirrors its fixes into the map while the
/// app is open, and keeps the WebSocket that delivers everyone else's
/// positions.
class TrackingController extends ChangeNotifier with WidgetsBindingObserver {
  TrackingController({
    required this.backend,
    required this.baseUrl,
    required this.getAccessToken,
    DeviceService? deviceService,
    BatteryService? batteryService,
    UserProfile? initialProfile,
  }) : deviceService = deviceService ?? DeviceService(baseUrl: baseUrl),
       batteryService = batteryService ?? BatteryService(),
       selfProfile =
           initialProfile ??
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

  final Backend backend;
  final String baseUrl;
  final String? Function() getAccessToken;
  final DeviceService deviceService;
  final BatteryService batteryService;
  final UserProfile selfProfile;

  bool isTracking = false;
  bool permissionGranted = false;
  LocationPoint? lastLocation;
  List<LocationPoint> history = [];
  List<UserProfile> peers = [];
  TrackingStatus status = const TrackingStatus();

  StreamSubscription<List<UserProfile>>? _peerSubscription;
  StreamSubscription<Map<String, dynamic>>? _engineSubscription;
  StreamSubscription<void>? _batterySubscription;
  Timer? _batteryRefreshTimer;
  bool _reregistering = false;

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
    return AppConstants.defaultMapCenter;
  }

  // ── App lifecycle ─────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _setAppForeground(true);
        // Permissions may have been changed in Settings meanwhile.
        if (isTracking) unawaited(_rearm());
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _setAppForeground(false);
        break;
      default:
        break;
    }
  }

  // Whether TrackingScreen currently has its Map tab selected, and whether
  // the app itself is in the foreground — combined, these decide whether the
  // live map is actually visible to the user right now. Both default to true
  // to match the app's initial state (Map is the landing tab, app opens
  // foregrounded).
  bool _isMapTabSelected = true;
  bool _isAppForeground = true;

  void _setAppForeground(bool foreground) {
    if (foreground) {
      backend.resume();
    } else {
      backend.suspend();
    }
    _isAppForeground = foreground;
    _syncMapActive();
    if (!isTracking) return;
    unawaited(TrackingEngine.setAppVisible(foreground));
    if (foreground) {
      _startBatteryMonitoring();
      unawaited(refreshStatus());
    } else {
      _stopBatteryMonitoring();
    }
  }

  /// Forwarded from [TrackingScreen] whenever the Map tab becomes or stops
  /// being the visible tab, so the server only asks devices to stream live
  /// while someone can actually see them move.
  void setMapTabSelected(bool selected) {
    _isMapTabSelected = selected;
    _syncMapActive();
  }

  void _syncMapActive() {
    backend.setMapActive(_isAppForeground && _isMapTabSelected);
  }

  // ── Tracking ──────────────────────────────────────────────────────────────

  Future<void> startTracking() async {
    if (isTracking) return;

    permissionGranted = await TrackingPermissions.request();
    if (!permissionGranted) {
      notifyListeners();
      return;
    }

    _engineSubscription ??= TrackingEngine.events.listen(_onEngineEvent);
    final configured = await _configureEngine();
    if (configured) {
      await TrackingEngine.start();
      await TrackingEngine.setAppVisible(_isAppForeground);
    }
    _startBatteryMonitoring();
    isTracking = true;
    notifyListeners();
    unawaited(refreshStatus());

    // Backend connection is best-effort; recording works without it.
    backend.initialize().catchError((_) {});
  }

  /// Pauses sharing: the engine disarms every trigger. Already-recorded
  /// points still upload.
  Future<void> stopTracking() async {
    if (!isTracking) return;
    await TrackingEngine.stop();
    _stopBatteryMonitoring();
    isTracking = false;
    notifyListeners();
    unawaited(refreshStatus());
  }

  Future<void> refreshStatus() async {
    status = await TrackingEngine.status();
    notifyListeners();
  }

  /// Re-applies configuration so the engine picks up permission changes.
  Future<void> _rearm() async {
    await TrackingEngine.start();
    await refreshStatus();
  }

  Future<bool> _configureEngine() async {
    final authHeader = await _uploadAuthHeader();
    if (authHeader == null) {
      unawaited(TrackingEngine.log('auth', 'Not configured: no session'));
      return false;
    }
    await TrackingEngine.configure(
      baseUrl: baseUrl,
      authHeader: authHeader,
      userId: selfProfile.id,
      batterySaver: selfProfile.batterySavingEnabled,
    );
    unawaited(_migrateLegacyQueue(authHeader));
    return true;
  }

  /// One-time upgrade step from the previous Dart/foreground-service
  /// implementation: uploads any points still sitting in its
  /// SharedPreferences outbox (already in the server's payload format), then
  /// removes its leftover keys.
  Future<void> _migrateLegacyQueue(String authHeader) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyOutboxKey);
    if (raw != null && raw.isNotEmpty && raw != '[]') {
      try {
        final response = await http
            .post(
              Uri.parse('$baseUrl/api/v1/location'),
              headers: {
                'content-type': 'application/json',
                'authorization': authHeader,
              },
              body: raw,
            )
            .timeout(const Duration(seconds: 30));
        // 400: nothing usable in there; anything else non-2xx: retry later.
        if (response.statusCode >= 300 && response.statusCode != 400) return;
        unawaited(TrackingEngine.log('upload', 'Uploaded the pre-upgrade queue'));
      } catch (_) {
        return;
      }
    }
    for (final key in _legacyKeys) {
      await prefs.remove(key);
    }
  }

  static const _legacyOutboxKey = 'pending_location_points';
  static const _legacyKeys = [
    _legacyOutboxKey,
    'pacing_mode',
    'battery_saving_enabled',
    'app_foreground',
    'bg_base_url',
    'bg_current_interval_ms',
    'bg_service_running',
    'debug_activity_log',
    'debug_last_tick',
    'debug_last_success',
  ];

  /// The engine's upload credential: this install's device token, registered
  /// once per account. Falls back to the session JWT against servers without
  /// device registration — refreshed into the engine whenever the app opens.
  Future<String?> _uploadAuthHeader({bool forceRegister = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = DeviceCredentialStore.load(prefs);
    if (!forceRegister && cached != null && cached.userId == selfProfile.id) {
      return cached.authHeader;
    }
    final accessToken = getAccessToken();
    if (accessToken == null) return cached?.authHeader;
    try {
      final credentials = await deviceService.register(
        accessToken,
        userId: selfProfile.id,
        platform: Platform.operatingSystem,
        replaces: cached?.deviceId,
      );
      await DeviceCredentialStore.save(prefs, credentials);
      unawaited(TrackingEngine.log('auth', 'Registered upload credentials'));
      return credentials.authHeader;
    } catch (error) {
      unawaited(
        TrackingEngine.log(
          'auth',
          'Device registration failed ($error); using the session token',
        ),
      );
      return 'Bearer $accessToken';
    }
  }

  void _onEngineEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'location':
        final point = TrackingFix.fromMap(event).toLocationPoint();
        if (!point.latitude.isFinite || !point.longitude.isFinite) return;
        lastLocation = point;
        history = [point, ...history].take(40).toList();
        selfProfile.lastLocation = point;
        selfProfile.history = history;
        notifyListeners();
        break;
      case 'state':
      case 'upload':
        unawaited(refreshStatus());
        break;
      case 'auth_required':
        unawaited(_reregister());
        break;
    }
  }

  /// The server rejected the engine's credential (revoked, or an expired
  /// session-token fallback): register a fresh one.
  Future<void> _reregister() async {
    if (_reregistering) return;
    _reregistering = true;
    try {
      final authHeader = await _uploadAuthHeader(forceRegister: true);
      if (authHeader == null) return;
      await TrackingEngine.configure(
        baseUrl: baseUrl,
        authHeader: authHeader,
        userId: selfProfile.id,
        batterySaver: selfProfile.batterySavingEnabled,
      );
    } finally {
      _reregistering = false;
    }
  }

  // Keep [selfProfile]'s battery fields fresh for our own marker: react to
  // charging-state changes immediately and re-poll the level periodically
  // (the platform doesn't push level changes). The engine reports battery
  // to the server itself.
  void _startBatteryMonitoring() {
    _refreshBattery();
    _batterySubscription?.cancel();
    _batterySubscription = batteryService.onChanged.listen(
      (_) => _refreshBattery(),
    );
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

  void updateProfile({required String name, required String avatarUrl}) {
    selfProfile.name = name;
    selfProfile.avatarUrl = avatarUrl;
    notifyListeners();
  }

  void setSelfProfile(UserProfile profile) {
    final previousBatterySavingEnabled = selfProfile.batterySavingEnabled;
    selfProfile.name = profile.name;
    selfProfile.avatarUrl = profile.avatarUrl;
    selfProfile.role = profile.role;
    selfProfile.batterySavingEnabled = profile.batterySavingEnabled;
    if (isTracking &&
        previousBatterySavingEnabled != profile.batterySavingEnabled) {
      unawaited(_configureEngine());
    }
    notifyListeners();
  }

  @override
  void dispose() {
    // The engine is deliberately left running: tracking outlives the UI.
    // Signing out stops it (see AuthProvider).
    WidgetsBinding.instance.removeObserver(this);
    _engineSubscription?.cancel();
    _peerSubscription?.cancel();
    _stopBatteryMonitoring();
    backend.dispose();
    super.dispose();
  }
}
