import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Long-lived upload credentials for the native tracking engine.
class DeviceCredentials {
  const DeviceCredentials({
    required this.deviceId,
    required this.token,
    required this.userId,
  });

  final String deviceId;
  final String token;
  final String userId;

  /// Value for the engine's `Authorization` header.
  String get authHeader => 'Device $token';
}

/// Registers this install with the server. The native engine uploads while
/// the app is closed — possibly for days — so it can't depend on the
/// short-lived session JWT; it presents a revocable device token instead.
class DeviceService {
  DeviceService({required String baseUrl, http.Client? httpClient})
    : _baseUri = Uri.parse(baseUrl),
      _httpClient = httpClient ?? http.Client();

  final Uri _baseUri;
  final http.Client _httpClient;

  Future<DeviceCredentials> register(
    String accessToken, {
    required String userId,
    required String platform,
    String? replaces,
  }) async {
    final response = await _httpClient
        .post(
          _baseUri.replace(path: '/api/v1/devices'),
          headers: {
            'content-type': 'application/json',
            'authorization': 'Bearer $accessToken',
          },
          body: jsonEncode({'platform': platform, 'replaces': ?replaces}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Device registration failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return DeviceCredentials(
      deviceId: body['device_id'] as String,
      token: body['device_token'] as String,
      userId: userId,
    );
  }

  /// Revokes [credentials] using the device token itself, so sign-out works
  /// even when the session JWT has already expired. [authHeader] overrides
  /// the stored token with the engine's current, rotated one.
  Future<void> unregister(
    DeviceCredentials credentials, {
    String? authHeader,
  }) async {
    await _httpClient
        .delete(
          _baseUri.replace(path: '/api/v1/devices/${credentials.deviceId}'),
          headers: {'authorization': authHeader ?? credentials.authHeader},
        )
        .timeout(const Duration(seconds: 10));
  }
}

/// Persists [DeviceCredentials] so registration happens once per install and
/// account rather than on every launch. The token stored here is the one
/// issued at registration: the server rotates it through the native engine's
/// uploads, so the engine holds the live copy (see `TrackingEngine.configure`).
class DeviceCredentialStore {
  DeviceCredentialStore._();

  static const _idKey = 'lt_device_id';
  static const _tokenKey = 'lt_device_token';
  static const _userKey = 'lt_device_user';

  static DeviceCredentials? load(SharedPreferences prefs) {
    final id = prefs.getString(_idKey);
    final token = prefs.getString(_tokenKey);
    final user = prefs.getString(_userKey);
    if (id == null || token == null || user == null) return null;
    return DeviceCredentials(deviceId: id, token: token, userId: user);
  }

  static Future<void> save(
    SharedPreferences prefs,
    DeviceCredentials credentials,
  ) async {
    await prefs.setString(_idKey, credentials.deviceId);
    await prefs.setString(_tokenKey, credentials.token);
    await prefs.setString(_userKey, credentials.userId);
  }

  static Future<void> clear(SharedPreferences prefs) async {
    await prefs.remove(_idKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
  }
}
