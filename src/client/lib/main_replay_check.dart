// Standalone harness for manually verifying the session-replay screen's
// playback smoothness, marker rendering, and terrain switcher on a device or
// emulator, without needing login or a backend.
//
// Run with:  flutter run -t lib/main_replay_check.dart -d <device>
import 'package:flutter/material.dart';

import 'src/data/models/location_model.dart';
import 'src/data/models/location_session.dart';
import 'src/features/tracking/widgets/session_replay_screen.dart';

void main() => runApp(const _ReplayCheckApp());

class _ReplayCheckApp extends StatelessWidget {
  const _ReplayCheckApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Replay check',
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: SessionReplayScreen(session: _buildFakeSession(), userName: 'Alice'),
    );
  }
}

LocationSession _buildFakeSession() {
  const startLat = 45.07031;
  const startLng = 7.68688; // Piazza Castello, Turin
  final start = DateTime.now().subtract(const Duration(minutes: 10));

  final points = <LocationPoint>[];
  // Irregular gaps (3s..14s) and varying speed/heading so the segment-duration
  // scaling and heading-beam rotation are both exercised.
  const gapsSeconds = [3, 5, 4, 8, 3, 14, 6, 4, 9, 5, 3, 7];
  var elapsed = 0;
  for (var i = 0; i < gapsSeconds.length + 1; i++) {
    final t = start.add(Duration(seconds: elapsed));
    final lat = startLat + i * 0.0009;
    final lng = startLng + i * 0.0006 + (i.isEven ? 0.0003 : -0.0003);
    points.add(
      LocationPoint(
        latitude: lat,
        longitude: lng,
        speed: 3.0 + (i % 4) * 2.5,
        heading: (i * 35) % 360,
        timestamp: t,
      ),
    );
    if (i < gapsSeconds.length) elapsed += gapsSeconds[i];
  }

  return LocationSession(
    startAt: points.first.timestamp,
    endAt: points.last.timestamp,
    durationSeconds: elapsed.toDouble(),
    distanceMeters: 850,
    avgSpeed: 6.0,
    topSpeed: 11.5,
    points: points,
  );
}
