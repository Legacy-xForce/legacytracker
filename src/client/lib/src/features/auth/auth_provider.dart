import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/user_model.dart';
import '../../data/network/auth_service.dart';
import '../../data/network/profile_service.dart';
import '../../data/storage/token_storage.dart';

class AuthProvider extends ChangeNotifier with WidgetsBindingObserver {
  AuthProvider({
    required this.authService,
    required this.profileService,
  }) {
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  final AuthService authService;
  final ProfileService profileService;
  TokenStorage? _storage;

  bool isInitializing = true;
  bool isLoading = false;
  bool isAuthenticated = false;
  String? username;
  AuthTokens? tokens;
  UserProfile? profile;
  String? errorMessage;

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
      } catch (_) {
        await _clearSession();
      }
    }
    isInitializing = false;
    notifyListeners();
  }

  Future<void> login(String username, String password) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final tokens = await authService.login(username.trim(), password);
      this.username = username.trim();
      this.tokens = tokens;
      isAuthenticated = true;
      await _storage?.save(this.username!, tokens);
      await _loadProfile();
    } catch (error) {
      errorMessage = error.toString();
      isAuthenticated = false;
      rethrow;
    } finally {
      isLoading = false;
      notifyListeners();
    }
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
      throw Exception('Refresh token expired');
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
    notifyListeners();
  }

  Future<void> _clearSession() async {
    username = null;
    tokens = null;
    profile = null;
    isAuthenticated = false;
    errorMessage = null;
    await _storage?.clear();
  }

  // The access token is short-lived; while the app sits backgrounded it can
  // expire without anything noticing, since [_refreshTokensIfNeeded] is
  // otherwise only checked at cold start. Re-checking on resume keeps
  // [tokens] valid before any screen or background service tries to use it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && isAuthenticated) {
      unawaited(_refreshOnResume());
    }
  }

  Future<void> _refreshOnResume() async {
    try {
      await _refreshTokensIfNeeded();
      notifyListeners();
    } catch (_) {
      await _clearSession();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
