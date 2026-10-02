import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/data/network/auth_service.dart';
import 'src/data/network/device_service.dart';
import 'src/data/network/profile_service.dart';
import 'src/data/network/remote_backend.dart';
import 'src/features/auth/auth_provider.dart';
import 'src/features/auth/login_screen.dart';
import 'src/features/tracking/tracking_controller.dart';
import 'src/features/tracking/tracking_screen.dart';
import 'src/data/models/user_model.dart';

class App extends StatelessWidget {
  App({super.key});

  static String _defaultBackendBaseUrl() => 'https://tracker.legacy-group.tech';

  final AuthService authService = AuthService();
  final ProfileService profileService = ProfileService(baseUrl: _defaultBackendBaseUrl());
  final DeviceService deviceService = DeviceService(baseUrl: _defaultBackendBaseUrl());

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => AuthProvider(
            authService: authService,
            profileService: profileService,
            deviceService: deviceService,
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
                    ? AuthenticatedApp(
                        selfId: auth.profile?.id ?? '',
                        profile: auth.profile,
                      )
                    : const LoginScreen(),
          );
        },
      ),
    );
  }
}

class AuthenticatedApp extends StatefulWidget {
  const AuthenticatedApp({
    super.key,
    required this.selfId,
    required this.profile,
  });

  final String selfId;
  final UserProfile? profile;

  @override
  State<AuthenticatedApp> createState() => _AuthenticatedAppState();
}

class _AuthenticatedAppState extends State<AuthenticatedApp> {
  TrackingController? _trackingController;
  late final AuthProvider _auth;

  static String _defaultBackendBaseUrl() => 'https://tracker.legacy-group.tech';

  @override
  void initState() {
    super.initState();
    _auth = Provider.of<AuthProvider>(context, listen: false);
    _registerFcmToken();
  }

  Future<void> _registerFcmToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      final baseUrl = _defaultBackendBaseUrl();
      final backend = RemoteBackend(
        baseUrl: baseUrl,
        getAccessToken: () => _auth.tokens!.accessToken,
        selfId: widget.selfId,
      );
      await backend.registerFcmToken(token);
      await backend.dispose();

      // Re-register when the token rotates.
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        final b = RemoteBackend(
          baseUrl: baseUrl,
          getAccessToken: () => _auth.tokens!.accessToken,
          selfId: widget.selfId,
        );
        await b.registerFcmToken(newToken);
        await b.dispose();
      });
    } catch (_) {
      // Firebase not configured — skip silently.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_trackingController == null) {
      if (!_auth.isAuthenticated) return;

      final baseUrl = _defaultBackendBaseUrl();
      final backend = RemoteBackend(
        baseUrl: baseUrl,
        getAccessToken: () => _auth.tokens!.accessToken,
        selfId: widget.selfId,
      );
      _trackingController = TrackingController(
        backend: backend,
        baseUrl: baseUrl,
        getAccessToken: () => _auth.tokens?.accessToken,
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
