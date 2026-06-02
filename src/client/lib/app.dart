import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'src/data/network/remote_backend.dart';
import 'src/features/location/location_repository.dart';
import 'src/features/location/location_service.dart';
import 'src/features/tracking/tracking_controller.dart';
import 'src/features/tracking/tracking_screen.dart';

class App extends StatelessWidget {
  App({super.key});

  static String _defaultBackendBaseUrl() {
    if (Platform.isAndroid) {
      return 'http://10.0.2.2:3000';
    }
    if (Platform.isIOS) {
      // Use the iOS simulator loopback address here.
      // For a physical device, point this to the host machine's LAN address.
      return 'http://127.0.0.1:3000';
    }
    return 'http://127.0.0.1:3000';
  }

  final RemoteBackend backend = RemoteBackend(
    baseUrl: _defaultBackendBaseUrl(),
    userId: 'me',
  );

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<TrackingController>(
          create: (_) => TrackingController(
            locationRepository: LocationRepository(
              locationService: GeolocatorLocationService(),
              backend: backend,
            ),
            backend: backend,
          ),
        ),
      ],
      child: MaterialApp(
        title: 'Legacy Tracker',
        themeMode: ThemeMode.dark,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
          brightness: Brightness.dark,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
          brightness: Brightness.dark,
        ),
        home: const TrackingScreen(),
      ),
    );
  }
}
