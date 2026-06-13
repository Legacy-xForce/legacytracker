import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/data/network/auth_service.dart';
import 'src/data/network/profile_service.dart';
import 'src/data/network/remote_backend.dart';
import 'src/features/auth/auth_provider.dart';
import 'src/features/auth/login_screen.dart';
import 'src/features/location/location_repository.dart';
import 'src/features/location/location_service.dart';
import 'src/features/tracking/tracking_controller.dart';
import 'src/features/tracking/tracking_screen.dart';
import 'src/data/models/user_model.dart';

class App extends StatelessWidget {
  App({super.key});

  static String _defaultBackendBaseUrl() {
    if (Platform.isAndroid) {
      return 'http://192.168.0.224:3000';
    }
    if (Platform.isIOS) {
      return 'http://192.168.0.224:3000';
    }
    return 'http://127.0.0.1:3000';
  }

  final AuthService authService = AuthService();
  final ProfileService profileService = ProfileService(baseUrl: _defaultBackendBaseUrl());

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => AuthProvider(
            authService: authService,
            profileService: profileService,
          ),
        ),
      ],
      child: Consumer<AuthProvider>(
        builder: (context, auth, child) {
          return MaterialApp(
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
            home: auth.isInitializing
                ? const Scaffold(body: Center(child: CircularProgressIndicator()))
                : auth.isAuthenticated
                    ? AuthenticatedApp(accessToken: auth.tokens!.accessToken, selfId: auth.profile?.id ?? '', profile: auth.profile)
                    : const LoginScreen(),
          );
        },
      ),
    );
  }
}

class AuthenticatedApp extends StatefulWidget {
  const AuthenticatedApp({super.key, required this.accessToken, required this.selfId, required this.profile});

  final String accessToken;
  final String selfId;
  final UserProfile? profile;

  @override
  State<AuthenticatedApp> createState() => _AuthenticatedAppState();
}

class _AuthenticatedAppState extends State<AuthenticatedApp> {
  TrackingController? _trackingController;

  static String _defaultBackendBaseUrl() {
    if (Platform.isAndroid) {
      return 'http://192.168.0.224:3000';
    }
    if (Platform.isIOS) {
      return 'http://192.168.0.224:3000';
    }
    return 'http://127.0.0.1:3000';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_trackingController == null) {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      if (!auth.isAuthenticated) {
        return;
      }

      final backend = RemoteBackend(
        baseUrl: _defaultBackendBaseUrl(),
        accessToken: widget.accessToken,
        selfId: widget.selfId,
      );
      _trackingController = TrackingController(
        locationRepository: LocationRepository(
          locationService: GeolocatorLocationService(),
          backend: backend,
        ),
        backend: backend,
        initialProfile: widget.profile ?? UserProfile(id: widget.selfId, name: widget.selfId),
      );
    }
  }

  @override
  void didUpdateWidget(covariant AuthenticatedApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.profile != null && _trackingController != null) {
      _trackingController!.setSelfProfile(widget.profile!);
    }
  }

  @override
  void dispose() {
    _trackingController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_trackingController == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return ChangeNotifierProvider<TrackingController>.value(
      value: _trackingController!,
      child: const TrackingScreen(),
    );
  }
}
