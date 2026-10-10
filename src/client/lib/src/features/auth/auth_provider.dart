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

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _storage = TokenStorage(prefs);
    final stored = await _storage!.load();
    if (stored != null) {
      username = stored.username;
      tokens = stored.tokens;
      try {
        if (await _refreshTokensIfNeeded()) {
          await _loadProfile();
          isAuthenticated = true;
        }
      } on AuthRejectedException {
        await _clearSession();
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
    return _signIn(() async {
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

  Future<void> _signIn(
    Future<(String, AuthTokens)> Function() authenticate,
  ) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final (username, tokens) = await authenticate();
      this.username = username;
      this.tokens = tokens;
      isAuthenticated = true;
      await _storage?.save(username, tokens);
      await _loadProfile();
    } catch (error) {
      final cancelled = error is PasskeyException && error.cancelled;
      errorMessage = cancelled ? null : _describe(error);
      isAuthenticated = false;
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

  Future<bool> _refreshTokensIfNeeded() async {
    if (tokens == null) {
      return false;
    }

    final now = DateTime.now();
    if (tokens!.expiresAt.isAfter(now.add(const Duration(seconds: 10)))) {
      return true;
    }

    if (tokens!.refreshExpiresAt.isBefore(now)) {
      throw AuthRejectedException('Refresh token expired');
    }

    tokens = await authService.refresh(tokens!.refreshToken);
    await _storage?.save(username!, tokens!);
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
    final parts = jwt?.split('.');
    if (parts == null || parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final value = payload is Map ? payload[claim] : null;
      return value is String && value.isNotEmpty ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearSession() async {
    await _stopSharing();
    username = null;
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
      await _refreshTokensIfNeeded();
      if (!_profileLoaded) await _loadProfile();
      notifyListeners();
    } on AuthRejectedException {
      await _clearSession();
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
