import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// The resource indicators (RFC 8707) of the two apps one sign-in covers. The
/// access token's `aud` is the plain app name.
const trackerResource = 'urn:legacy:tracker';
const calendarResource = 'urn:legacy:calendar';

/// What an account the OP turned away is told.
const noTrackerAccessMessage = 'This account can\'t use Legacy Tracker.';

// `offline_access` gets a refresh token; the OP only grants it with
// `prompt=consent`, which it answers without asking.
const _baseScopes = 'openid profile offline_access tracker.read tracker.write';
const _calendarScope = 'calendar.read';

/// The OP refused the sign-in (`error=access_denied`).
class SignInDeniedException extends AuthException {
  SignInDeniedException({required this.calendarRequested})
    : super(noTrackerAccessMessage, statusCode: 403);

  /// The sign-in asked for the calendar too; possibly only that was refused.
  final bool calendarRequested;
}

/// A sign-in under way: what the browser opens, and what checks the answer.
class AuthorizationRequest {
  AuthorizationRequest({
    required this.url,
    required this.state,
    required this.nonce,
    required this.codeVerifier,
    required this.withCalendar,
  });

  final Uri url;
  final String state;
  final String nonce;
  final String codeVerifier;
  final bool withCalendar;
}

/// Tokens from the OP's token endpoint.
class OidcTokens {
  OidcTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.idToken,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String? idToken;
}

/// Legacy Auth's OpenID Provider, spoken to as the public client
/// `tracker-mobile`: authorization code with PKCE in the system browser, then
/// plain token-endpoint calls. Every token request names the app (`resource`)
/// it wants a token for. See docs/oidc-migration.md.
class OidcService {
  OidcService({
    required String issuer,
    required this.clientId,
    required this.redirectUri,
    required this.postLogoutRedirectUri,
    http.Client? httpClient,
  }) : _issuer = issuer.replaceFirst(RegExp(r'/+$'), ''),
       _httpClient = httpClient ?? http.Client();

  final String _issuer;
  final String clientId;
  final String redirectUri;
  final String postLogoutRedirectUri;
  final http.Client _httpClient;
  static const _timeout = Duration(seconds: 15);

  Map<String, dynamic>? _metadata;

  String get issuer => _issuer;

  Future<Map<String, dynamic>> _discovery() async {
    if (_metadata case final metadata?) return metadata;
    final response = await _send(
      () => _httpClient.get(
        Uri.parse('$_issuer/.well-known/openid-configuration'),
      ),
    );
    if (response.statusCode != 200) {
      throw AuthException(
        'The sign-in server had a problem (error ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    final metadata = jsonDecode(response.body) as Map<String, dynamic>;
    if (metadata['issuer'] != _issuer) {
      throw AuthException('Unexpected answer from the sign-in server.');
    }
    return _metadata = metadata;
  }

  Future<Uri> _endpoint(String name) async {
    final value = (await _discovery())[name];
    if (value is! String) {
      throw AuthException('The sign-in server has no $name.');
    }
    return Uri.parse(value);
  }

  /// Starts a sign-in. One grant covers the tracker and, [withCalendar], the
  /// calendar.
  Future<AuthorizationRequest> authorizationRequest({
    required bool withCalendar,
  }) async {
    final endpoint = await _endpoint('authorization_endpoint');
    final state = _random();
    final nonce = _random();
    final verifier = _random();
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    // Built by hand: `resource` appears once per app.
    final query = [
      ('client_id', clientId),
      ('redirect_uri', redirectUri),
      ('response_type', 'code'),
      ('scope', withCalendar ? '$_baseScopes $_calendarScope' : _baseScopes),
      ('prompt', 'consent'),
      ('state', state),
      ('nonce', nonce),
      ('code_challenge', challenge),
      ('code_challenge_method', 'S256'),
      ('resource', trackerResource),
      if (withCalendar) ('resource', calendarResource),
    ].map((p) => '${Uri.encodeQueryComponent(p.$1)}=${Uri.encodeQueryComponent(p.$2)}');
    return AuthorizationRequest(
      url: endpoint.replace(query: query.join('&')),
      state: state,
      nonce: nonce,
      codeVerifier: verifier,
      withCalendar: withCalendar,
    );
  }

  /// Completes [request] from the URL the browser was sent back to, trading
  /// the code for a tracker token.
  Future<OidcTokens> exchangeCode(
    AuthorizationRequest request,
    Uri callback,
  ) async {
    final params = callback.queryParameters;
    if (params['state'] != request.state) {
      throw AuthException('Sign-in failed. Please try again.');
    }
    // RFC 9207: the answer must come from our OP.
    if (params['iss'] case final iss? when iss != _issuer) {
      throw AuthException('Sign-in failed. Please try again.');
    }
    if (params['error'] == 'access_denied') {
      throw SignInDeniedException(calendarRequested: request.withCalendar);
    }
    final code = params['code'];
    if (params['error'] != null || code == null) {
      throw AuthException('Sign-in failed. Please try again.');
    }
    final tokens = await _token({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': request.codeVerifier,
      'resource': trackerResource,
    });
    final idToken = tokens.idToken;
    if (idToken == null) {
      throw AuthException('Unexpected answer from the sign-in server.');
    }
    _checkIdToken(idToken, request.nonce);
    return tokens;
  }

  /// Trades [refreshToken] for an access token to [resource]. The OP rotates
  /// the refresh token on every use: store the new one before anything else
  /// uses the grant. Throws [AuthRejectedException] when the OP refuses it.
  Future<OidcTokens> refresh(String refreshToken, String resource) {
    return _token({
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'resource': resource,
    });
  }

  /// Where to send the browser to end the OP session (every Legacy app
  /// signed in through it on this phone's browser).
  Future<Uri> endSessionUrl(String? idToken) async {
    final endpoint = await _endpoint('end_session_endpoint');
    return endpoint.replace(
      queryParameters: {
        'client_id': clientId,
        'post_logout_redirect_uri': postLogoutRedirectUri,
        'id_token_hint': ?idToken,
      },
    );
  }

  Future<OidcTokens> _token(Map<String, String> form) async {
    final endpoint = await _endpoint('token_endpoint');
    final response = await _send(
      () => _httpClient.post(endpoint, body: {...form, 'client_id': clientId}),
    );
    if (response.statusCode >= 400 && response.statusCode < 500) {
      final body = _json(response.body);
      final error = body?['error'] ?? response.statusCode;
      throw AuthRejectedException(
        body?['error_description'] as String? ?? 'Session rejected ($error)',
      );
    }
    if (response.statusCode != 200) {
      throw AuthException(
        'The sign-in server had a problem (error ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    final body = _json(response.body);
    final accessToken = body?['access_token'];
    final refreshToken = body?['refresh_token'];
    if (accessToken is! String || refreshToken is! String) {
      throw AuthException('Unexpected answer from the sign-in server.');
    }
    final expiresIn = body?['expires_in'];
    return OidcTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: DateTime.now().add(
        Duration(seconds: expiresIn is int ? expiresIn : 300),
      ),
      idToken: body?['id_token'] as String?,
    );
  }

  /// The ID token came straight from the token endpoint over TLS, so its
  /// claims are checked but not its signature (OIDC Core 3.1.3.7).
  void _checkIdToken(String idToken, String nonce) {
    final claims = jwtClaims(idToken);
    final aud = claims?['aud'];
    final audiences = aud is List ? aud : [aud];
    final exp = claims?['exp'];
    final valid =
        claims != null &&
        claims['iss'] == _issuer &&
        audiences.contains(clientId) &&
        claims['nonce'] == nonce &&
        exp is num &&
        DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000)
            .isAfter(DateTime.now());
    if (!valid) throw AuthException('Sign-in failed. Please try again.');
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw AuthException('The server took too long to answer. Try again.');
    } on http.ClientException {
      throw AuthException(
        'Can\'t reach the server. Check your connection and try again.',
      );
    }
  }

  static Map<String, dynamic>? _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String _random() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

/// The claims of a JWT, unverified: for display and for deciding what to ask
/// for. The servers do the verifying.
Map<String, dynamic>? jwtClaims(String? jwt) {
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
