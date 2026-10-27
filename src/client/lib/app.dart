import 'package:dynamic_color/dynamic_color.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/core/constants.dart';
import 'src/core/theme.dart';
import 'src/core/theme_settings.dart';
import 'src/data/network/auth_service.dart';
import 'src/data/network/calendar_service.dart';
import 'src/data/network/checkpoint_service.dart';
import 'src/data/network/device_service.dart';
import 'src/data/network/oidc_service.dart';
import 'src/data/network/event_geocoder.dart';
import 'src/data/network/place_search_service.dart';
import 'src/data/network/profile_service.dart';
import 'src/data/network/remote_backend.dart';
import 'src/data/network/sharing_service.dart';
import 'src/features/auth/auth_provider.dart';
import 'src/features/auth/login_screen.dart';
import 'src/features/calendar/calendar_events_provider.dart';
import 'src/features/checkpoints/checkpoints_provider.dart';
import 'src/features/connection/connection_banner.dart';
import 'src/features/connection/connection_monitor.dart';
import 'src/features/tracking/map_settings.dart';
import 'src/features/tracking/sharing_provider.dart';
import 'src/features/tracking/tracking_controller.dart';
import 'src/features/tracking/tracking_screen.dart';
import 'src/features/updates/update_required_gate.dart';
import 'src/data/models/user_model.dart';

class App extends StatelessWidget {
  App({super.key});

  final AuthService authService = AuthService(baseUrl: AppConstants.authBaseUrl);
  final OidcService oidcService = OidcService(
    issuer: AppConstants.authBaseUrl,
    clientId: AppConstants.oidcClientId,
    redirectUri: AppConstants.oidcRedirectUri,
    postLogoutRedirectUri: AppConstants.oidcPostLogoutRedirectUri,
  );
  final ProfileService profileService = ProfileService(baseUrl: AppConstants.backendBaseUrl);
  final DeviceService deviceService = DeviceService(baseUrl: AppConstants.backendBaseUrl);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Outside the auth gate so the login screen reports a dead connection
        // too.
        ChangeNotifierProvider<ConnectionMonitor>(
          create: (_) =>
              ConnectionMonitor(baseUrl: AppConstants.backendBaseUrl)..start(),
        ),
        // Above the MaterialApp so the replay screen sees the default too.
        ChangeNotifierProvider<MapSettings>(create: (_) => MapSettings()),
        // Above the MaterialApp so a theme picked in the profile repaints
        // every screen right away.
        ChangeNotifierProvider<ThemeSettings>(create: (_) => ThemeSettings()),
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => AuthProvider(
            authService: authService,
            oidcService: oidcService,
            callbackScheme: AppConstants.oidcCallbackScheme,
            profileService: profileService,
            deviceService: deviceService,
          ),
        ),
        // Above the MaterialApp so pushed routes (history, the checkpoints
        // screen) can read it. Loads only once the account is fully usable.
        ChangeNotifierProxyProvider<AuthProvider, CheckpointsProvider>(
          create: (_) => CheckpointsProvider(
            service: CheckpointService(baseUrl: AppConstants.backendBaseUrl),
            prefs: SharedPreferences.getInstance(),
          ),
          update: (_, auth, checkpoints) {
            final usable = auth.isAuthenticated;
            return checkpoints!
              ..bindSession(
                userId: usable ? auth.profile?.id : null,
                getAccessToken: () => auth.accessToken,
              );
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, SharingProvider>(
          create: (_) => SharingProvider(
            service: SharingService(baseUrl: AppConstants.backendBaseUrl),
          ),
          update: (_, auth, sharing) {
            final usable = auth.isAuthenticated;
            return sharing!
              ..bindSession(
                userId: usable ? auth.profile?.id : null,
                getAccessToken: () => auth.accessToken,
              );
          },
        ),
        // Events from Legacy Calendar on the map, for accounts with the
        // calendar, read with a calendar token from the same sign-in.
        ChangeNotifierProxyProvider<AuthProvider, CalendarEventsProvider>(
          create: (_) {
            final prefs = SharedPreferences.getInstance();
            return CalendarEventsProvider(
              service: CalendarService(baseUrl: AppConstants.calendarBaseUrl),
              geocoder: EventGeocoder(search: PlaceSearchService(), prefs: prefs),
              prefs: prefs,
            );
          },
          update: (_, auth, events) {
            final usable = auth.isAuthenticated;
            return events!
              ..bindSession(
                userId: usable ? auth.profile?.id : null,
                hasCalendarScope: auth.hasCalendarScope,
                getAccessToken: () => auth.calendarAccessToken,
              );
          },
        ),
      ],
      child: Consumer2<AuthProvider, ThemeSettings>(
        builder: (context, auth, themeSettings, child) {
          // Kept in the tree for fixed themes too: swapping it in only for
          // Adaptive would remount the MaterialApp and send the user back to
          // the map when they pick a theme from the profile tab.
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              if (themeSettings.themeId == AppThemeId.adaptive) {
                // Android hands us the wallpaper's palette (Material You);
                // other platforms fall back to the teal palette in the
                // system brightness.
                return _materialApp(
                  auth,
                  themeMode: ThemeMode.system,
                  theme: buildAppTheme(
                    lightDynamic ?? adaptiveScheme(Brightness.light),
                  ),
                  darkTheme: buildAppTheme(
                    darkDynamic ?? adaptiveScheme(Brightness.dark),
                  ),
                );
              }

              if (themeSettings.themeId == AppThemeId.oledAdaptive) {
                // The phone's accents over the OLED's black surfaces. Held to
                // dark: a white background would not be an OLED theme.
                final adaptiveOnBlack = buildAppTheme(
                  oledSurfaces(darkDynamic ?? adaptiveScheme(Brightness.dark)),
                );
                return _materialApp(
                  auth,
                  themeMode: ThemeMode.dark,
                  theme: adaptiveOnBlack,
                  darkTheme: adaptiveOnBlack,
                );
              }

              final selected = buildThemeFor(themeSettings.themeId);
              return _materialApp(
                auth,
                themeMode: themeSettings.theme.brightness == Brightness.dark
                    ? ThemeMode.dark
                    : ThemeMode.light,
                theme: selected,
                darkTheme: selected,
              );
            },
          );
        },
      ),
    );
  }

  Widget _materialApp(
    AuthProvider auth, {
    required ThemeMode themeMode,
    required ThemeData theme,
    required ThemeData darkTheme,
  }) {
    return MaterialApp(
      title: 'Legacy Tracker',
      themeMode: themeMode,
      theme: theme,
      darkTheme: darkTheme,
      builder: (context, child) =>
          ConnectionBannerOverlay(child: child ?? const SizedBox.shrink()),
      // Blocks builds the server no longer supports, signed in or not.
      home: UpdateRequiredGate(child: _home(auth)),
    );
  }

  Widget _home(AuthProvider auth) {
    if (auth.isInitializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!auth.isAuthenticated) return const LoginScreen();
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
        getAccessToken: () => _auth.accessToken ?? '',
        selfId: widget.selfId,
      );
      await backend.registerFcmToken(token);
      await backend.dispose();

      // Re-register when the token rotates.
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        final b = RemoteBackend(
          baseUrl: baseUrl,
          getAccessToken: () => _auth.accessToken ?? '',
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
        getAccessToken: () => _auth.accessToken ?? '',
        selfId: widget.selfId,
      );
      _trackingController = TrackingController(
        backend: backend,
        baseUrl: baseUrl,
        getAccessToken: () => _auth.accessToken,
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
