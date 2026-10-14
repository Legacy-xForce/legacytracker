import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/core/constants.dart';
import 'src/core/theme.dart';
import 'src/data/network/auth_service.dart';
import 'src/data/network/checkpoint_service.dart';
import 'src/data/network/device_service.dart';
import 'src/data/network/profile_service.dart';
import 'src/data/network/remote_backend.dart';
import 'src/features/auth/access_denied_screen.dart';
import 'src/features/auth/auth_provider.dart';
import 'src/features/auth/login_screen.dart';
import 'src/features/checkpoints/checkpoints_provider.dart';
import 'src/features/tracking/tracking_controller.dart';
import 'src/features/tracking/tracking_screen.dart';
import 'src/data/models/user_model.dart';

class App extends StatelessWidget {
  App({super.key});

  final AuthService authService = AuthService();
  final ProfileService profileService = ProfileService(baseUrl: AppConstants.backendBaseUrl);
  final DeviceService deviceService = DeviceService(baseUrl: AppConstants.backendBaseUrl);

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
        // Above the MaterialApp so pushed routes (history, the checkpoints
        // screen) can read it. Loads only once the account is fully usable.
        ChangeNotifierProxyProvider<AuthProvider, CheckpointsProvider>(
          create: (_) => CheckpointsProvider(
            service: CheckpointService(baseUrl: AppConstants.backendBaseUrl),
          ),
          update: (_, auth, checkpoints) {
            final usable = auth.isAuthenticated && auth.accessDenial == null;
            return checkpoints!
              ..bindSession(
                userId: usable ? auth.profile?.id : null,
                getAccessToken: () => auth.tokens?.accessToken,
              );
          },
        ),
      ],
      child: Consumer<AuthProvider>(
        builder: (context, auth, child) {
          return MaterialApp(
            title: 'Legacy Tracker',
            themeMode: ThemeMode.dark,
            theme: buildAppTheme(),
            darkTheme: buildAppTheme(),
            home: _home(auth),
          );
        },
      ),
    );
  }

  Widget _home(AuthProvider auth) {
    if (auth.isInitializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (auth.accessDenial == AccessDenial.accountDisabled) {
      return const AccountDisabledScreen();
    }
    if (!auth.isAuthenticated) return const LoginScreen();
    if (auth.accessDenial == AccessDenial.missingScope) {
      return const MissingScopeScreen();
    }
    return AuthenticatedApp(
      selfId: auth.profile?.id ?? '',
      profile: auth.profile,
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

      final baseUrl = AppConstants.backendBaseUrl;
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

      final baseUrl = AppConstants.backendBaseUrl;
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
