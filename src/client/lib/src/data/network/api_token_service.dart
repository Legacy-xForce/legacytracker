import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/api_token.dart';

/// A request the server refused, with a message safe to show to the user.
class ApiTokenException implements Exception {
  ApiTokenException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The account's tokens, and the address the API read that request from —
/// offered as a one-click entry, so limiting a token does not mean guessing
/// where it will be seen to come from.
class ApiTokenList {
  const ApiTokenList({required this.tokens, this.yourIp});

  final List<ApiToken> tokens;
  final String? yourIp;
}

/// Creates, lists, rotates and deletes the user's personal API tokens. These
/// calls need the signed-in session's access token; API tokens themselves
/// can't manage tokens.
class ApiTokenService {
  ApiTokenService({required String baseUrl, http.Client? httpClient})
    : _baseUri = Uri.parse(baseUrl),
      _httpClient = httpClient ?? http.Client();

  final Uri _baseUri;
  final http.Client _httpClient;

  Future<ApiTokenList> list(String accessToken) async {
    final response = await _send(
      () => _httpClient.get(
        _uri('/api/v1/api-tokens'),
        headers: _headers(accessToken),
      ),
    );
    _check(response, expected: 200, fallback: 'The tokens could not be read.');
    final body = _json(response);
    final tokens = <ApiToken>[];
    for (final json in body['tokens'] as List<dynamic>? ?? const []) {
      try {
        tokens.add(ApiToken.fromJson(json as Map<String, dynamic>));
      } on Object {
        // A malformed entry only drops that row.
      }
    }
    return ApiTokenList(
      tokens: tokens,
      yourIp: body['your_ip'] is String ? body['your_ip'] as String : null,
    );
  }

  /// Every live token on the tracker, whoever owns it, for the shared audit
  /// view. Deleted tokens are not listed.
  Future<List<ApiToken>> listAll(String accessToken) async {
    final response = await _send(
      () => _httpClient.get(
        _uri('/api/v1/api-tokens/all'),
        headers: _headers(accessToken),
      ),
    );
    _check(response, expected: 200, fallback: 'The tokens could not be read.');
    final body = _json(response);
    final tokens = <ApiToken>[];
    for (final json in body['tokens'] as List<dynamic>? ?? const []) {
      try {
        tokens.add(ApiToken.fromJson(json as Map<String, dynamic>));
      } on Object {
        // A malformed entry only drops that row.
      }
    }
    return tokens;
  }

  Future<IssuedApiToken> create(
    String accessToken, {
    required String name,
    required ApiTokenScope scope,
  }) async {
    final response = await _send(
      () => _httpClient.post(
        _uri('/api/v1/api-tokens'),
        headers: _headers(accessToken, json: true),
        body: jsonEncode({'name': name, 'scope': scope.name}),
      ),
    );
    _check(
      response,
      expected: 201,
      fallback: 'The token could not be created.',
    );
    return _issued(response);
  }

  Future<IssuedApiToken> rotate(String accessToken, String id) async {
    final response = await _send(
      () => _httpClient.post(
        _uri('/api/v1/api-tokens/${Uri.encodeComponent(id)}/rotate'),
        headers: _headers(accessToken),
      ),
    );
    _check(
      response,
      expected: 200,
      fallback: 'The token could not be rotated.',
    );
    return _issued(response);
  }

  /// Replaces the addresses a token may be used from; an empty list lifts the
  /// restriction. Returns the token as the server now has it.
  Future<ApiToken> updateAllowedIps(
    String accessToken,
    String id,
    List<String> allowedIps,
  ) async {
    final response = await _send(
      () => _httpClient.patch(
        _uri('/api/v1/api-tokens/${Uri.encodeComponent(id)}'),
        headers: _headers(accessToken, json: true),
        body: jsonEncode({'allowed_ips': allowedIps}),
      ),
    );
    _check(
      response,
      expected: 200,
      fallback: 'The addresses could not be saved.',
    );
    try {
      return ApiToken.fromJson(_json(response));
    } on Object {
      throw ApiTokenException(
        'The server sent an unexpected reply. Try again.',
      );
    }
  }

  Future<void> delete(String accessToken, String id) async {
    final response = await _send(
      () => _httpClient.delete(
        _uri('/api/v1/api-tokens/${Uri.encodeComponent(id)}'),
        headers: _headers(accessToken),
      ),
    );
    _check(
      response,
      expected: 200,
      fallback: 'The token could not be deleted.',
    );
  }

  /// One page of what was requested with [id], newest first. [before] is the
  /// `nextBefore` of the previous page.
  Future<ApiTokenRequestPage> requests(
    String accessToken,
    String id, {
    String? before,
    int limit = 50,
  }) async {
    final response = await _send(
      () => _httpClient.get(
        _uri(
          '/api/v1/api-tokens/${Uri.encodeComponent(id)}/requests',
          queryParameters: {'limit': '$limit', 'before': ?before},
        ),
        headers: _headers(accessToken),
      ),
    );
    _check(
      response,
      expected: 200,
      fallback: 'The request history could not be read.',
    );
    final body = _json(response);
    final requests = <ApiTokenRequest>[];
    for (final json in body['requests'] as List<dynamic>? ?? const []) {
      try {
        requests.add(ApiTokenRequest.fromJson(json as Map<String, dynamic>));
      } on Object {
        // A malformed entry only drops that row.
      }
    }
    return ApiTokenRequestPage(
      requests: requests,
      hasMore: body['has_more'] == true,
      nextBefore: body['next_before'] is String
          ? body['next_before'] as String
          : null,
    );
  }

  IssuedApiToken _issued(http.Response response) {
    try {
      return IssuedApiToken.fromJson(_json(response));
    } on Object {
      throw ApiTokenException(
        'The server sent an unexpected reply. Try again.',
      );
    }
  }

  // Hints contain "…": decode as UTF-8 whatever charset the reply names.
  static Map<String, dynamic> _json(http.Response response) =>
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

  Uri _uri(String path, {Map<String, String>? queryParameters}) =>
      _baseUri.replace(path: path, queryParameters: queryParameters);

  // Only requests with a body name a JSON type: the server answers 400 to an
  // empty body that claims to be JSON.
  Map<String, String> _headers(String accessToken, {bool json = false}) => {
    if (json) 'content-type': 'application/json',
    'authorization': 'Bearer $accessToken',
  };

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(const Duration(seconds: 15));
    } on Exception {
      throw ApiTokenException(
        'Unable to reach the server. Check your connection and try again.',
      );
    }
  }

  void _check(
    http.Response response, {
    required int expected,
    required String fallback,
  }) {
    if (response.statusCode == expected) return;
    switch (response.statusCode) {
      case 404:
        throw ApiTokenException('This token no longer exists.');
      case 400:
        throw ApiTokenException(_serverMessage(response) ?? fallback);
      default:
        throw ApiTokenException(
          'Something went wrong (${response.statusCode}). Try again.',
        );
    }
  }

  String? _serverMessage(http.Response response) {
    try {
      final body = _json(response);
      return body['error'] as String?;
    } catch (_) {
      return null;
    }
  }
}
