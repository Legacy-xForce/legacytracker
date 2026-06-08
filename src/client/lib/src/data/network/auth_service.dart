import 'dart:convert';

import 'package:http/http.dart' as http;

import '../storage/token_storage.dart';

class AuthService {
  AuthService({http.Client? httpClient, String? baseUrl})
      : _httpClient = httpClient ?? http.Client(),
        _baseUri = Uri.parse(baseUrl ?? _defaultBaseUrl);

  static const String _defaultBaseUrl = 'http://caccabot.duckdns.org:4000';
  final Uri _baseUri;
  final http.Client _httpClient;

  Future<AuthTokens> login(String username, String password) async {
    final response = await _httpClient.post(
      _baseUri.replace(path: '/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );

    if (response.statusCode != 200) {
      throw Exception('Login failed: ${response.body.isEmpty ? response.reasonPhrase : response.body}');
    }

    return _parseTokenResponse(response.body);
  }

  Future<AuthTokens> refresh(String refreshToken) async {
    final response = await _httpClient.post(
      _baseUri.replace(path: '/auth/refresh'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );

    if (response.statusCode != 200) {
      throw Exception('Token refresh failed: ${response.body.isEmpty ? response.reasonPhrase : response.body}');
    }

    return _parseTokenResponse(response.body);
  }

  Future<void> logout(String refreshToken) async {
    try {
      await _httpClient.post(
        _baseUri.replace(path: '/auth/logout'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      );
    } catch (_) {
      // Best effort revoke; ignore errors during logout.
    }
  }

  AuthTokens _parseTokenResponse(String body) {
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final expiresIn = decoded['expires_in'] as int;
    final refreshExpiresIn = decoded['refresh_expires_in'] as int;
    return AuthTokens(
      accessToken: decoded['access_token'] as String,
      refreshToken: decoded['refresh_token'] as String,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      refreshExpiresAt: DateTime.now().add(Duration(seconds: refreshExpiresIn)),
    );
  }
}
