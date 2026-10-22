import 'dart:convert';

import 'package:http/http.dart' as http;

import '../storage/token_storage.dart';

/// The auth server definitively refused the session (invalid or expired
/// refresh token) — as opposed to a network failure, which is transient.
class AuthRejectedException implements Exception {
  AuthRejectedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A failed auth request, with a [message] fit to show the user.
class AuthException implements Exception {
  AuthException(this.message, {this.statusCode});

  final String message;

  /// Null when the server couldn't be reached at all.
  final int? statusCode;

  @override
  String toString() => message;
}

/// An administrator disabled the account in Legacy Auth. Thrown when
/// refreshing a legacy session; it also means the session is over (an
/// [AuthRejectedException]): the auth server revokes every refresh token of a
/// disabled account.
class AccountDisabledException extends AuthException
    implements AuthRejectedException {
  AccountDisabledException()
    : super('This account has been disabled.', statusCode: 403);
}

/// The old password-login session (`/auth/refresh`, `/auth/logout`), kept for
/// sessions started before the move to OpenID Connect until they fail. New
/// sign-ins go through [OidcService].
class AuthService {
  AuthService({http.Client? httpClient, String? baseUrl})
      : _httpClient = httpClient ?? http.Client(),
        _baseUri = Uri.parse(baseUrl ?? _defaultBaseUrl);

  static const String _defaultBaseUrl = 'https://auth.legacy-group.tech';
  final Uri _baseUri;
  final http.Client _httpClient;

  Future<AuthTokens> refresh(String refreshToken) async {
    final response = await _httpClient.post(
      _baseUri.replace(path: '/auth/refresh'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );

    if (response.statusCode == 403 && _serverError(response) == 'Account disabled') {
      throw AccountDisabledException();
    }
    if (response.statusCode >= 400 && response.statusCode < 500) {
      throw AuthRejectedException('Token refresh rejected (${response.statusCode})');
    }
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

  /// The `error` text of a JSON error response, if it has one.
  static String? _serverError(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] is String) return body['error'] as String;
    } catch (_) {
      // Not JSON (a proxy error page, say).
    }
    return null;
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
