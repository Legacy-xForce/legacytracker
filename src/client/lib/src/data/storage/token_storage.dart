import 'package:shared_preferences/shared_preferences.dart';

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

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['expires_at'] as int).toInt(),
      ),
      refreshExpiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['refresh_expires_at'] as int).toInt(),
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_at': expiresAt.millisecondsSinceEpoch,
      'refresh_expires_at': refreshExpiresAt.millisecondsSinceEpoch,
    };
  }
}

class StoredAuthData {
  final String username;
  final AuthTokens tokens;

  StoredAuthData({required this.username, required this.tokens});
}

class TokenStorage {
  TokenStorage(this._prefs);

  static const _usernameKey = 'auth_username';
  static const _accessTokenKey = 'auth_access_token';
  static const _refreshTokenKey = 'auth_refresh_token';
  static const _expiresAtKey = 'auth_expires_at';
  static const _refreshExpiresAtKey = 'auth_refresh_expires_at';

  final SharedPreferences _prefs;

  Future<StoredAuthData?> load() async {
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

  Future<void> save(String username, AuthTokens tokens) async {
    await _prefs.setString(_usernameKey, username);
    await _prefs.setString(_accessTokenKey, tokens.accessToken);
    await _prefs.setString(_refreshTokenKey, tokens.refreshToken);
    await _prefs.setInt(_expiresAtKey, tokens.expiresAt.millisecondsSinceEpoch);
    await _prefs.setInt(_refreshExpiresAtKey, tokens.refreshExpiresAt.millisecondsSinceEpoch);
  }

  Future<void> clear() async {
    await _prefs.remove(_usernameKey);
    await _prefs.remove(_accessTokenKey);
    await _prefs.remove(_refreshTokenKey);
    await _prefs.remove(_expiresAtKey);
    await _prefs.remove(_refreshExpiresAtKey);
  }
}
