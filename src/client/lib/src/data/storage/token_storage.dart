import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tokens of the old password login (`/auth/login`), which sessions started
/// before the move to OpenID Connect keep refreshing until that fails.
class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final DateTime refreshExpiresAt;

  AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.refreshExpiresAt,
  });
}

class StoredAuthData {
  final String username;
  final AuthTokens tokens;

  StoredAuthData({required this.username, required this.tokens});
}

/// An OpenID Connect grant: what survives a restart. Access tokens are kept
/// in memory only.
class StoredGrant {
  StoredGrant({
    required this.refreshToken,
    required this.idToken,
    required this.calendar,
    required this.userId,
    required this.username,
  });

  final String refreshToken;

  /// Sent as the hint when signing out at the OP.
  final String? idToken;

  /// Whether the grant was asked for the calendar too.
  final bool calendar;

  /// Who signed in, so the app can start offline.
  final String userId;
  final String username;

  StoredGrant withRefreshToken(String refreshToken) => StoredGrant(
    refreshToken: refreshToken,
    idToken: idToken,
    calendar: calendar,
    userId: userId,
    username: username,
  );

  Map<String, dynamic> toJson() => {
    'refresh_token': refreshToken,
    'id_token': idToken,
    'calendar': calendar,
    'user_id': userId,
    'username': username,
  };

  static StoredGrant? fromJson(Object? json) {
    if (json is! Map) return null;
    final refreshToken = json['refresh_token'];
    final userId = json['user_id'];
    if (refreshToken is! String || userId is! String) return null;
    final username = json['username'];
    final idToken = json['id_token'];
    return StoredGrant(
      refreshToken: refreshToken,
      idToken: idToken is String ? idToken : null,
      calendar: json['calendar'] == true,
      userId: userId,
      username: username is String ? username : userId,
    );
  }
}

/// Where the session lives: the OIDC grant in the platform's secure storage
/// (Keychain, Android Keystore-backed encrypted preferences), a legacy
/// password-login session where it always was, in SharedPreferences.
class TokenStorage {
  TokenStorage(this._prefs, {FlutterSecureStorage? secure})
    : _secure = secure ?? const FlutterSecureStorage();

  static const _grantKey = 'oidc_grant';

  static const _usernameKey = 'auth_username';
  static const _accessTokenKey = 'auth_access_token';
  static const _refreshTokenKey = 'auth_refresh_token';
  static const _expiresAtKey = 'auth_expires_at';
  static const _refreshExpiresAtKey = 'auth_refresh_expires_at';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  Future<StoredGrant?> loadGrant() async {
    final raw = await _secure.read(key: _grantKey);
    if (raw == null) return null;
    try {
      return StoredGrant.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveGrant(StoredGrant grant) =>
      _secure.write(key: _grantKey, value: jsonEncode(grant.toJson()));

  Future<StoredAuthData?> loadLegacy() async {
    final username = _prefs.getString(_usernameKey);
    final accessToken = _prefs.getString(_accessTokenKey);
    final refreshToken = _prefs.getString(_refreshTokenKey);
    final expiresAt = _prefs.getInt(_expiresAtKey);
    final refreshExpiresAt = _prefs.getInt(_refreshExpiresAtKey);

    if (username == null || accessToken == null || refreshToken == null || expiresAt == null || refreshExpiresAt == null) {
      return null;
    }

    return StoredAuthData(
      username: username,
      tokens: AuthTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
        refreshExpiresAt: DateTime.fromMillisecondsSinceEpoch(refreshExpiresAt),
      ),
    );
  }

  Future<void> saveLegacy(String username, AuthTokens tokens) async {
    await _prefs.setString(_usernameKey, username);
    await _prefs.setString(_accessTokenKey, tokens.accessToken);
    await _prefs.setString(_refreshTokenKey, tokens.refreshToken);
    await _prefs.setInt(_expiresAtKey, tokens.expiresAt.millisecondsSinceEpoch);
    await _prefs.setInt(_refreshExpiresAtKey, tokens.refreshExpiresAt.millisecondsSinceEpoch);
  }

  Future<void> clearLegacy() async {
    await _prefs.remove(_usernameKey);
    await _prefs.remove(_accessTokenKey);
    await _prefs.remove(_refreshTokenKey);
    await _prefs.remove(_expiresAtKey);
    await _prefs.remove(_refreshExpiresAtKey);
  }

  Future<void> clear() async {
    await _secure.delete(key: _grantKey);
    await clearLegacy();
  }
}
