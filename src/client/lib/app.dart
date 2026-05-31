import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'src/data/network/remote_backend.dart';
import 'src/features/location/location_repository.dart';
import 'src/features/location/location_service.dart';
import 'src/features/tracking/tracking_controller.dart';
import 'src/features/tracking/tracking_screen.dart';

class App extends StatelessWidget {
  App({super.key});

  final RemoteBackend backend = RemoteBackend(
    baseUrl: 'http://10.0.2.2:3000',
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
