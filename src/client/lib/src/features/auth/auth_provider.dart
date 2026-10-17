import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/user_model.dart';
import '../../data/network/auth_service.dart';
import '../../data/network/device_service.dart';
import '../../data/network/oidc_service.dart';
import '../../data/network/profile_service.dart';
import '../../data/storage/token_storage.dart';
import '../location/tracking_engine.dart';
import 'token_manager.dart';

/// Opens [url] in the system browser (Custom Tabs, ASWebAuthenticationSession)
/// and completes with the URL it was sent back to on [callbackScheme].
typedef BrowserAuth = Future<String> Function(Uri url, String callbackScheme);

Future<String> _systemBrowser(Uri url, String callbackScheme) =>
    FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackScheme,
    );

/// The session: signing in through Legacy Auth's OpenID Provider in the
/// system browser (password or passkey, shared with the phone's browser), and
/// keeping a tracker token and, for accounts with the calendar, a calendar
/// token valid. An account the OP turns away never gets a session; one that
/// loses access is signed out at its next refresh.
class AuthProvider extends ChangeNotifier with WidgetsBindingObserver {
  AuthProvider({
    required this.authService,
    required this.oidcService,
    required this.profileService,
    required this.callbackScheme,
    this.deviceService,
    BrowserAuth? browser,
    Future<TokenStorage> Function()? storage,
  }) : _browser = browser ?? _systemBrowser,
       _storageFactory = storage ?? _defaultStorage {
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  final AuthService authService;
  final OidcService oidcService;
  final ProfileService profileService;
  final DeviceService? deviceService;
  final String callbackScheme;
  final BrowserAuth _browser;
  final Future<TokenStorage> Function() _storageFactory;
  TokenManager? _tokens;

  bool isInitializing = true;
  bool isLoading = false;
  bool isAuthenticated = false;
  String? username;
  UserProfile? profile;

  /// Why the last sign-in failed or the session ended, for the sign-in screen.
  String? errorMessage;

  // False while [profile] is a placeholder built offline from the session.
  bool _profileLoaded = false;
  bool _foreground = true;
  Timer? _refreshTimer;

  static Future<TokenStorage> _defaultStorage() async =>
      TokenStorage(await SharedPreferences.getInstance());

  /// The current tracker access token. Kept fresh in the foreground; use
  /// [freshAccessToken] when a request can wait for a refresh.
  String? get accessToken => _tokens?.accessToken;

  /// A token Legacy Calendar accepts, or null without calendar access.
  String? get calendarAccessToken => _tokens?.calendarAccessToken;

  /// Whether the account may use Legacy Calendar. Display gating only; the
  /// calendar server enforces it.
  bool get hasCalendarScope => calendarAccessToken != null;

  Future<void> _initialize() async {
    final tokens = _tokens = TokenManager(
      oidc: oidcService,
      legacyAuth: authService,
      storage: await _storageFactory(),
    );
    await tokens.load();
    if (tokens.hasSession) {
      username = tokens.username;
      try {
        // OP access tokens aren't stored: a launch always starts with a refresh.
        await tokens.refreshTracker();
        await _refreshCalendar();
        await _loadProfile();
        isAuthenticated = true;
      } on AuthRejectedException catch (error) {
        await _clearSession(message: _endMessage(error));
      } catch (_) {
        // Offline (or a server hiccup) at launch must not sign the user out —
        // that would also stop location sharing. Continue on the stored
        // session; tokens and profile follow once the server is reachable.
        _useOfflineProfile();
      }
      _scheduleRefresh();
    }
    isInitializing = false;
    notifyListeners();
  }

  /// Signs in at Legacy Auth in the system browser. Completes normally if the
  /// user closes the browser — that's not an error worth reporting.
  Future<void> signIn() async {
    final tokens = _tokens;
    if (tokens == null || isLoading) return;
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      var withCalendar = true;
      while (true) {
        final request = await oidcService.authorizationRequest(
          withCalendar: withCalendar,
        );
        try {
          final callback = await _browser(request.url, callbackScheme);
          await tokens.adoptSignIn(
            await oidcService.exchangeCode(request, Uri.parse(callback)),
            calendar: withCalendar,
          );
          break;
        } on SignInDeniedException catch (error) {
          // Possibly only the calendar was refused. Ask again for the tracker
          // alone; the browser is already signed in, so it closes right away.
          if (!error.calendarRequested) rethrow;
          withCalendar = false;
        }
      }
      username = tokens.username;
      await _refreshCalendar();
      await _ensureProfile();
      isAuthenticated = true;
      _scheduleRefresh();
    } on PlatformException catch (error) {
      // CANCELED: the user closed the browser.
      if (error.code != 'CANCELED') {
        errorMessage = 'Couldn\'t open the sign-in page. Please try again.';
      }
    } catch (error) {
      errorMessage = _describe(error);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// A valid access token, refreshed first if it is about to expire. Throws
  /// when the session can't be renewed.
  Future<String> freshAccessToken() async {
    final tokens = _tokens;
    if (tokens == null || !tokens.hasSession) {
      throw AuthException('You\'re signed out. Sign in again to continue.');
    }
    try {
      await tokens.refreshTracker();
    } on AuthRejectedException catch (error) {
      await _clearSession(message: _endMessage(error));
      notifyListeners();
      throw AuthException('You\'re signed out. Sign in again to continue.');
    }
    _scheduleRefresh();
    return tokens.accessToken!;
  }

  static String _describe(Object error) {
    if (error is AuthException) return error.message;
    if (error is AuthRejectedException) {
      return 'Sign-in failed. Please try again.';
    }
    // Plain exceptions from the profile fetch read "Exception: …".
    return error.toString().replaceFirst(RegExp(r'^Exception: '), '');
  }

  /// What the sign-in screen says after the session was refused.
  static String _endMessage(AuthRejectedException error) {
    if (error is AccountDisabledException) return error.message;
    if (error.message == noTrackerAccessMessage ||
        error.message.contains('no access to tracker')) {
      return noTrackerAccessMessage;
    }
    return sessionEndedMessage;
  }

  /// Signs out on this phone, then at Legacy Auth (which ends the session in
  /// the phone's browser too, so the next sign-in asks again).
  Future<void> logout() async {
    final tokens = _tokens;
    isLoading = true;
    notifyListeners();
    String? idToken;
    var hadGrant = false;
    try {
      idToken = tokens?.idToken;
      hadGrant = (tokens?.hasSession ?? false) && !(tokens?.isLegacy ?? true);
      if (tokens?.isLegacy ?? false) {
        final legacy = await tokens!.storage.loadLegacy();
        if (legacy != null) await authService.logout(legacy.tokens.refreshToken);
      }
    } finally {
      await _clearSession();
      isLoading = false;
      notifyListeners();
    }
    if (hadGrant) {
      try {
        await _browser(await oidcService.endSessionUrl(idToken), callbackScheme);
      } catch (_) {
        // Closed or offline: this phone is signed out either way.
      }
    }
  }

  Future<void> updateProfile({required String name, required String avatarUrl}) async {
    if (username == null) {
      return;
    }
    isLoading = true;
    notifyListeners();
    try {
      profile = await profileService.updateProfile(
        await freshAccessToken(),
        name: name.trim(),
        avatarUrl: avatarUrl.trim(),
      );
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshCalendar() async {
    try {
      await _tokens?.refreshCalendar();
    } catch (_) {
      // Offline: the calendar waits for the next refresh round.
    }
  }

  Future<void> _loadProfile() async {
    final token = accessToken;
    if (token == null) return;
    profile = await profileService.fetchProfile(token);
    _profileLoaded = true;
    notifyListeners();
  }

  /// Loads the profile unless it already is, falling back to the offline
  /// placeholder when the tracker server can't be reached.
  Future<void> _ensureProfile() async {
    if (_profileLoaded) return;
    try {
      await _loadProfile();
    } catch (_) {
      _useOfflineProfile();
    }
  }

  /// Signs in from the stored session alone, identifying the user by the
  /// account id (the server's user id).
  void _useOfflineProfile() {
    final userId = _tokens?.userId;
    if (userId == null) return;
    profile ??= UserProfile(id: userId, name: username ?? userId);
    isAuthenticated = true;
  }

  /// Ends the session on this phone, leaving [message] for the sign-in screen.
  Future<void> _clearSession({String? message}) async {
    _refreshTimer?.cancel();
    await _stopSharing();
    await _tokens?.clear();
    username = null;
    profile = null;
    _profileLoaded = false;
    isAuthenticated = false;
    errorMessage = message;
  }

  /// Ends location sharing for this account: the engine makes a last upload
  /// attempt and wipes its queue, and the device's upload token is revoked.
  /// Best effort — signing out must work offline too.
  Future<void> _stopSharing() async {
    String? engineHeader;
    try {
      engineHeader = await TrackingEngine.stop(
        clearData: true,
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      // The engine finishes on its own; don't hold up sign-out.
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final credentials = DeviceCredentialStore.load(prefs);
      await DeviceCredentialStore.clear(prefs);
      if (credentials != null) {
        // The engine's token is newer than ours once the server rotated it.
        final current = engineHeader?.startsWith('Device ') == true
            ? engineHeader
            : null;
        await deviceService?.unregister(credentials, authHeader: current);
      }
    } catch (_) {
      // Offline: the token stays valid server-side but is harmless — the
      // engine has already discarded its copy.
    }
  }

  /// Renews the tokens a minute before the first one expires, while the app
  /// is in the foreground: the screens read [accessToken] as it is. (Background
  /// location uploads don't need it: the engine uses its own device token.)
  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final tokens = _tokens;
    if (!_foreground || tokens == null || !tokens.hasSession) return;
    final expiries = [tokens.trackerExpiresAt, tokens.calendarExpiresAt].nonNulls;
    // No token yet (offline at launch): try again shortly.
    final due = expiries.isEmpty
        ? DateTime.now().add(const Duration(seconds: 30))
        : expiries.reduce((a, b) => a.isBefore(b) ? a : b)
              .subtract(const Duration(minutes: 1));
    var delay = due.difference(DateTime.now());
    if (delay < const Duration(seconds: 5)) delay = const Duration(seconds: 5);
    _refreshTimer = Timer(delay, () => unawaited(_refreshSession()));
  }

  Future<void> _refreshSession() async {
    final tokens = _tokens;
    if (tokens == null || !tokens.hasSession) return;
    try {
      await tokens.refreshTracker();
      await _refreshCalendar();
      await _ensureProfile();
      isAuthenticated = true;
      notifyListeners();
    } on AuthRejectedException catch (error) {
      await _clearSession(message: _endMessage(error));
      notifyListeners();
      return;
    } catch (_) {
      // Transient (offline); the next round tries again.
    }
    _scheduleRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      if (isAuthenticated) unawaited(_refreshSession());
    } else if (state == AppLifecycleState.paused) {
      _foreground = false;
      _refreshTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
