import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/passkey.dart';
import '../../data/models/user_model.dart';
import '../../data/network/auth_service.dart';
import '../../data/network/device_service.dart';
import '../../data/network/profile_service.dart';
import '../../data/storage/token_storage.dart';
import '../location/tracking_engine.dart';
import 'passkey_client.dart';

/// Why an account can't use the tracker, as decided by Legacy Auth.
enum AccessDenial {
  /// An administrator disabled the account. The session is over; only a
  /// different account can sign in.
  accountDisabled,

  /// The account hasn't been granted the `tracker` scope. The session is
  /// kept so access can be checked again once an administrator grants it.
  missingScope,
}

class AuthProvider extends ChangeNotifier with WidgetsBindingObserver {
  AuthProvider({
    required this.authService,
    required this.profileService,
    this.deviceService,
    PasskeyClient? passkeyClient,
  }) : passkeyClient =
           passkeyClient ?? PasskeyClient(authService: authService) {
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  final AuthService authService;
  final ProfileService profileService;
  final DeviceService? deviceService;
  final PasskeyClient passkeyClient;
  TokenStorage? _storage;

  bool isInitializing = true;
  bool isLoading = false;
  bool isAuthenticated = false;
  String? username;
  AuthTokens? tokens;
  UserProfile? profile;
  String? errorMessage;

  // False while [profile] is a placeholder built offline from the token.
  bool _profileLoaded = false;
  bool _accountDisabled = false;

  /// Set when the account may not use the tracker; the app explains why
  /// instead of showing the map. [username] still names the account.
  AccessDenial? get accessDenial {
    if (_accountDisabled) return AccessDenial.accountDisabled;
    final accessToken = tokens?.accessToken;
    if (accessToken != null && !_hasTrackerScope(accessToken)) {
      return AccessDenial.missingScope;
    }
    return null;
  }

  /// Whether the account may use Legacy Calendar, whose API takes the same
  /// access token. Display gating only; the calendar server enforces it.
  bool get hasCalendarScope {
    final accessToken = tokens?.accessToken;
    return accessToken != null && _hasScope(accessToken, 'calendar');
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _storage = TokenStorage(prefs);
    final stored = await _storage!.load();
    if (stored != null) {
      username = stored.username;
      tokens = stored.tokens;
      try {
        if (await _refreshTokensIfNeeded()) {
          if (accessDenial == null) await _loadProfile();
          isAuthenticated = true;
        }
      } on AuthRejectedException catch (error) {
        await _clearSession(disabled: error is AccountDisabledException);
      } catch (_) {
        // Offline (or a server hiccup) at launch must not sign the user out —
        // that would also stop location sharing. Continue on the stored
        // session; tokens and profile refresh on the next resume.
        _useOfflineProfile();
      }
    }
    isInitializing = false;
    notifyListeners();
  }

  Future<void> login(String username, String password) {
    return _signIn(attemptedUsername: username.trim(), () async {
      final tokens = await authService.login(username.trim(), password);
      return (username.trim(), tokens);
    });
  }

  /// Signs in with a passkey on this device. Completes normally if the user
  /// dismisses the system prompt — that's not an error worth reporting.
  Future<void> loginWithPasskey() async {
    try {
      await _signIn(() async {
        final tokens = await passkeyClient.signIn();
        // No username was typed; the auth server puts it in the token.
        final name = _tokenClaim(tokens.accessToken, 'username') ??
            _tokenClaim(tokens.accessToken, 'sub')!;
        return (name, tokens);
      });
    } on PasskeyException catch (error) {
      if (!error.cancelled) rethrow;
    }
  }

  /// [attemptedUsername] names the account on the "account disabled" screen
  /// when the auth server refuses it.
  Future<void> _signIn(
    Future<(String, AuthTokens)> Function() authenticate, {
    String? attemptedUsername,
  }) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final (username, tokens) = await authenticate();
      this.username = username;
      this.tokens = tokens;
      isAuthenticated = true;
      await _storage?.save(username, tokens);
      // Without the tracker scope the server would refuse the profile; the
      // app shows why instead.
      if (accessDenial == null) await _loadProfile();
    } catch (error) {
      final cancelled = error is PasskeyException && error.cancelled;
      errorMessage = cancelled ? null : _describe(error);
      isAuthenticated = false;
      if (error is AccountDisabledException) {
        _accountDisabled = true;
        username = attemptedUsername;
      }
      rethrow;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// The account's passkeys, or null when the auth server has them disabled.
  Future<List<Passkey>?> loadPasskeys() async {
    return authService.listPasskeys(await _freshAccessToken());
  }

  /// Creates a passkey on this device for the signed-in account. Returns
  /// null if the user dismissed the system prompt.
  Future<Passkey?> createPasskey() async {
    try {
      return await passkeyClient.create(await _freshAccessToken());
    } on PasskeyException catch (error) {
      if (error.cancelled) return null;
      rethrow;
    }
  }

  Future<void> deletePasskey(String id) async {
    await authService.deletePasskey(await _freshAccessToken(), id);
  }

  Future<String> _freshAccessToken() async {
    if (!await _refreshTokensIfNeeded()) {
      throw AuthException('You\'re signed out. Sign in again to continue.');
    }
    return tokens!.accessToken;
  }

  static String _describe(Object error) {
    if (error is AuthException || error is PasskeyException) {
      return error.toString();
    }
    // Plain exceptions from the profile fetch read "Exception: …".
    return error.toString().replaceFirst(RegExp(r'^Exception: '), '');
  }

  Future<void> logout() async {
    isLoading = true;
    notifyListeners();

    try {
      if (tokens?.refreshToken != null) {
        await authService.logout(tokens!.refreshToken);
      }
    } finally {
      await _clearSession();
      isLoading = false;
      notifyListeners();
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
        tokens!.accessToken,
        name: name.trim(),
        avatarUrl: avatarUrl.trim(),
      );
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Checks again whether the account has the tracker scope, which an
  /// administrator may have granted since. True when it now has access.
  Future<bool> retryAccess() async {
    isLoading = true;
    notifyListeners();
    try {
      await _refreshTokensIfNeeded();
      if (accessDenial == null) await _ensureProfile();
      return accessDenial == null;
    } on AuthRejectedException catch (error) {
      await _clearSession(disabled: error is AccountDisabledException);
      return false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> _refreshTokensIfNeeded() async {
    if (tokens == null) {
      return false;
    }

    final now = DateTime.now();
    final hadAccess = accessDenial == null;
    // A token without the tracker scope is renewed even while it's valid:
    // the new one carries the account's current scopes.
    if (hadAccess &&
        tokens!.expiresAt.isAfter(now.add(const Duration(seconds: 10)))) {
      return true;
    }

    if (tokens!.refreshExpiresAt.isBefore(now)) {
      throw AuthRejectedException('Refresh token expired');
    }

    tokens = await authService.refresh(tokens!.refreshToken);
    await _storage?.save(username!, tokens!);
    // Losing tracker access stops location sharing, as signing out does.
    if (hadAccess && accessDenial != null) await _stopSharing();
    return true;
  }

  Future<void> _loadProfile() async {
    if (username == null) {
      return;
    }
    profile = await profileService.fetchProfile(tokens!.accessToken);
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
  /// access token's subject (the server's user id).
  void _useOfflineProfile() {
    final userId = _tokenClaim(tokens?.accessToken, 'sub');
    if (userId == null) return;
    profile ??= UserProfile(id: userId, name: username ?? userId);
    isAuthenticated = true;
  }

  /// A string claim from a JWT's payload. Unverified — only for display and
  /// identifying ourselves; the servers do the verifying.
  static String? _tokenClaim(String? jwt, String claim) {
    final value = _tokenPayload(jwt)?[claim];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Whether the access token grants the tracker: Legacy Auth sends
  /// `scopes: {calendar: bool, tracker: bool}`. The tracker server applies
  /// the same rule; this only decides what the app shows.
  static bool _hasTrackerScope(String jwt) => _hasScope(jwt, 'tracker');

  static bool _hasScope(String jwt, String scope) {
    final scopes = _tokenPayload(jwt)?['scopes'];
    return scopes is Map && scopes[scope] == true;
  }

  static Map<String, dynamic>? _tokenPayload(String? jwt) {
    final parts = jwt?.split('.');
    if (parts == null || parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return payload is Map<String, dynamic> ? payload : null;
    } catch (_) {
      return null;
    }
  }

  /// Ends the session on this phone. When the account was [disabled], the
  /// username is kept so the explanation can name the account.
  Future<void> _clearSession({bool disabled = false}) async {
    await _stopSharing();
    if (!disabled) username = null;
    _accountDisabled = disabled;
    tokens = null;
    profile = null;
    _profileLoaded = false;
    isAuthenticated = false;
    errorMessage = null;
    await _storage?.clear();
  }

  /// Ends location sharing for this account: the engine makes a last upload
  /// attempt and wipes its queue, and the device's upload token is revoked.
  /// Best effort — signing out must work offline too.
  Future<void> _stopSharing() async {
    try {
      await TrackingEngine.stop(
        clearData: true,
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      // The engine finishes on its own; don't hold up sign-out.
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final credentials = DeviceCredentialStore.load(prefs);
      await DeviceCredentialStore.clear(prefs);
      if (credentials != null) await deviceService?.unregister(credentials);
    } catch (_) {
      // Offline: the token stays valid server-side but is harmless — the
      // engine has already discarded its copy.
    }
  }

  // The access token is short-lived; while the app sits backgrounded it can
  // expire without anything noticing, since [_refreshTokensIfNeeded] is
  // otherwise only checked at cold start. Re-checking on resume keeps
  // [tokens] valid before any screen tries to use it. (Background location
  // uploads don't need it: the engine uses its own device token.)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && isAuthenticated) {
      unawaited(_refreshOnResume());
    }
  }

  Future<void> _refreshOnResume() async {
    try {
      // Also picks up a tracker scope granted while the app was away.
      await _refreshTokensIfNeeded();
      if (accessDenial == null) await _ensureProfile();
      notifyListeners();
    } on AuthRejectedException catch (error) {
      await _clearSession(disabled: error is AccountDisabledException);
      notifyListeners();
    } catch (_) {
      // Transient (offline); try again on the next resume.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
