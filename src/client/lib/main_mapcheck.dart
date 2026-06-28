// Standalone harness for manually verifying the tracking map's zoom/bounds
// behaviour on a device or emulator, without needing login or a backend.
//
// Run with:  flutter run -t lib/main_mapcheck.dart -d <device>
//
// `self` is nudged along a short route every 500ms so the marker-motion ticks
// (and therefore the auto-follow camera moves) stay active — this is exactly
// the condition under which a pinch used to blank the map.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'src/data/models/location_model.dart';
import 'src/data/models/user_model.dart';
import 'src/features/tracking/widgets/tracking_map_layer.dart';
import 'src/features/tracking/widgets/tracking_map_tab.dart';

void main() => runApp(const _MapCheckApp());

class _MapCheckApp extends StatelessWidget {
  const _MapCheckApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Map bounds check',
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: const _MapCheckScreen(),
    );
  }
}

class _MapCheckScreen extends StatefulWidget {
  const _MapCheckScreen();

  @override
  State<_MapCheckScreen> createState() => _MapCheckScreenState();
}

class _MapCheckScreenState extends State<_MapCheckScreen> {
  static const _start = LatLng(45.07031, 7.68688); // Piazza Castello, Turin

  late final UserProfile _self;
  late final UserProfile _peer;
  Timer? _timer;
  int _tick = 0;
  MapLayer _layer = MapLayer.standard;

  @override
  void initState() {
    super.initState();
    _self = UserProfile(
      id: 'self',
      name: 'Me',
      lastLocation: LocationPoint(
        latitude: _start.latitude,
        longitude: _start.longitude,
        speed: 8.0,
        heading: 180,
      ),
      batteryLevel: 82,
    );
    _peer = UserProfile(
      id: 'peer',
      name: 'Bob',
      lastLocation: LocationPoint(
        latitude: _start.latitude + 0.002,
        longitude: _start.longitude + 0.002,
        speed: 5.0,
        heading: 90,
      ),
      batteryLevel: 47,
    );

    // Keep self moving so auto-follow keeps calling MapController.move().
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _tick++;
      final lat = _start.latitude + (_tick % 40) * 0.0004;
      final lng = _start.longitude + (_tick % 40) * 0.0003;
      setState(() {
        _self.lastLocation = LocationPoint(
          latitude: lat,
          longitude: lng,
          speed: 8.0,
          heading: 150,
        );
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TrackingMapTab(
        isActive: true,
        center: _start,
        selectedLayer: _layer,
        peers: [_peer],
        selfProfile: _self,
        selfTrackingPaused: false,
        selfMissingPermissions: false,
        selfBatterySavingEnabled: false,
        selectedUserId: null,
        onLayerSelected: (l) => setState(() => _layer = l),
        onUserSelected: (_) {},
        onUserTap: (_) {},
      ),
    );
  }
}
