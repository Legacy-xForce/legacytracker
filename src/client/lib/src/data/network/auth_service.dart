import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/passkey.dart';
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

/// An administrator disabled the account in Legacy Auth. Thrown both when
/// signing in (an [AuthException]) and when refreshing, where it also means
/// the session is over (an [AuthRejectedException]): the auth server revokes
/// every refresh token of a disabled account.
class AccountDisabledException extends AuthException
    implements AuthRejectedException {
  AccountDisabledException()
    : super('This account has been disabled.', statusCode: 403);
}

/// The passkey used to sign in is no longer on the account (deleted, maybe
/// from another phone), though the phone still offers it.
class PasskeyNotRegisteredException extends AuthException {
  PasskeyNotRegisteredException(int statusCode)
    : super(
        'That passkey was removed from your account. Sign in with your '
        'password instead.',
        statusCode: statusCode,
      );
}

class AuthService {
  AuthService({http.Client? httpClient, String? baseUrl})
      : _httpClient = httpClient ?? http.Client(),
        _baseUri = Uri.parse(baseUrl ?? _defaultBaseUrl);

  static const String _defaultBaseUrl = 'https://auth.legacy-group.tech';
  static const _timeout = Duration(seconds: 15);

  /// The app these sign-ins are for. Naming it keeps the access token's `aud`
  /// to the tracker, so the token cannot be replayed against another app.
  static const _audience = 'tracker';
  final Uri _baseUri;
  final http.Client _httpClient;

  Future<AuthTokens> login(String username, String password) async {
    final response = await _send(
      () => _httpClient.post(
        _baseUri.replace(path: '/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password, 'audience': _audience}),
      ),
    );

    if (response.statusCode == 401) {
      throw AuthException('Wrong username or password.', statusCode: 401);
    }
    _ensureOk(response, 'Sign-in failed');
    return _parseTokenResponse(response.body);
  }

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

  /// WebAuthn request options for a passkey sign-in, as JSON.
  Future<Map<String, dynamic>> passkeyLoginOptions() async {
    final response = await _send(
      () => _httpClient.post(
        _baseUri.replace(path: '/auth/passkey/login-options'),
        headers: {'content-type': 'application/json'},
        // No username: any passkey the phone holds for this server will do.
        body: '{}',
      ),
    );
    _ensurePasskeysAvailable(response);
    _ensureOk(response, 'Passkey sign-in is unavailable');
    final options = jsonDecode(response.body) as Map<String, dynamic>;
    return {...options, 'rpId': options['rpId'] ?? _relyingPartyId};
  }

  /// Exchanges the authenticator's assertion for a session. Throws a
  /// [PasskeyNotRegisteredException] if the passkey was deleted from the
  /// account.
  Future<AuthTokens> passkeyLogin(Map<String, dynamic> assertion) async {
    final response = await _send(
      () => _httpClient.post(
        _baseUri.replace(path: '/auth/passkey/login-verify'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({...assertion, 'audience': _audience}),
      ),
    );
    if (response.statusCode == 404 ||
        _serverError(response) == 'Unknown passkey credential') {
      throw PasskeyNotRegisteredException(response.statusCode);
    }
    _ensureOk(response, 'Passkey sign-in failed');
    return _parseTokenResponse(response.body);
  }

  /// WebAuthn creation options for adding a passkey to the signed-in account.
  Future<Map<String, dynamic>> passkeyRegistrationOptions(String accessToken) async {
    final response = await _send(
      () => _httpClient.post(
        _baseUri.replace(path: '/auth/passkey/register-options'),
        headers: _bearer(accessToken),
      ),
    );
    _ensurePasskeysAvailable(response);
    _ensureOk(response, 'Couldn\'t start creating a passkey');
    final options = jsonDecode(response.body) as Map<String, dynamic>;
    final rp = options['rp'] as Map<String, dynamic>? ?? const {};
    return {
      ...options,
      'rp': {...rp, 'id': rp['id'] ?? _relyingPartyId},
    };
  }

  /// Stores a new passkey. [attestation] is the authenticator's registration
  /// response; the server also needs the credential's [publicKey]
  /// (SubjectPublicKeyInfo, base64url), which it doesn't read from it.
  Future<Passkey> registerPasskey(
    String accessToken,
    Map<String, dynamic> attestation, {
    required String publicKey,
    String? name,
  }) async {
    final response = await _send(
      () => _httpClient.post(
        _baseUri.replace(path: '/auth/passkey/register-verify'),
        headers: {'content-type': 'application/json', ..._bearer(accessToken)},
        body: jsonEncode({
          ...attestation,
          'response': {
            ...attestation['response'] as Map<String, dynamic>,
            'publicKey': publicKey,
          },
          'deviceName': ?name,
        }),
      ),
    );
    _ensureOk(response, 'Couldn\'t save the passkey');
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return Passkey(
      id: body['credentialId'] as String,
      name: body['deviceName'] as String? ?? name ?? 'Passkey',
      createdAt: DateTime.now(),
    );
  }

  /// The account's passkeys, or null when the server has no passkeys.
  Future<List<Passkey>?> listPasskeys(String accessToken) async {
    final response = await _send(
      () => _httpClient.get(
        _baseUri.replace(path: '/auth/passkey/credentials'),
        headers: _bearer(accessToken),
      ),
    );
    // Servers from before passkeys don't know the route.
    if (response.statusCode == 404) return null;
    _ensureOk(response, 'Couldn\'t load your passkeys');
    return (jsonDecode(response.body) as List<dynamic>)
        .map((item) => Passkey.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> deletePasskey(String accessToken, String id) async {
    final response = await _send(
      () => _httpClient.delete(
        _baseUri.replace(path: '/auth/passkey/credentials/$id'),
        headers: _bearer(accessToken),
      ),
    );
    // Already gone counts as done.
    if (response.statusCode == 404) return;
    _ensureOk(response, 'Couldn\'t remove the passkey');
  }

  /// Passkeys belong to the auth server's host. Its options leave the RP ID
  /// out, as a browser on that host fills it in with the host itself, but
  /// the platform authenticators need it spelled out.
  String get _relyingPartyId => _baseUri.host;

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw AuthException('The server took too long to answer. Try again.');
    } on http.ClientException {
      throw AuthException('Can\'t reach the server. Check your connection and try again.');
    }
  }

  /// 404: an auth server from before passkeys; 503: passkeys not configured.
  void _ensurePasskeysAvailable(http.Response response) {
    if (response.statusCode == 404 || response.statusCode == 503) {
      throw AuthException(
        'Passkeys aren\'t available yet. Sign in with your password.',
        statusCode: response.statusCode,
      );
    }
  }

  /// Throws an [AuthException] for any non-2xx response, preferring the
  /// server's own `error` text — it's written for people ("Account disabled").
  void _ensureOk(http.Response response, String fallback) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final serverMessage = _serverError(response);
    if (serverMessage == 'Account disabled') throw AccountDisabledException();
    final message = switch (serverMessage) {
      final String text when response.statusCode < 500 => _sentence(text),
      _ => '$fallback (error ${response.statusCode}).',
    };
    throw AuthException(message, statusCode: response.statusCode);
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

  static String _sentence(String text) =>
      text.endsWith('.') || text.endsWith('!') ? text : '$text.';

  Map<String, String> _bearer(String accessToken) => {'authorization': 'Bearer $accessToken'};

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
