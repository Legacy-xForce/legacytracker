import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/api_token.dart';
import 'api_client.dart';

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
    : _api = ApiClient(baseUrl: baseUrl, httpClient: httpClient);

  final ApiClient _api;

  Future<ApiTokenList> list(String accessToken) async {
    final response = await _api.send(
      () => _api.httpClient.get(
        _api.uri('/api/v1/api-tokens'),
        headers: _api.headers(accessToken),
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
    final response = await _api.send(
      () => _api.httpClient.get(
        _api.uri('/api/v1/api-tokens/all'),
        headers: _api.headers(accessToken),
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
    final response = await _api.send(
      () => _api.httpClient.post(
        _api.uri('/api/v1/api-tokens'),
        headers: _api.headers(accessToken, json: true),
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
    final response = await _api.send(
      () => _api.httpClient.post(
        _api.uri('/api/v1/api-tokens/${Uri.encodeComponent(id)}/rotate'),
        headers: _api.headers(accessToken),
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
    final response = await _api.send(
      () => _api.httpClient.patch(
        _api.uri('/api/v1/api-tokens/${Uri.encodeComponent(id)}'),
        headers: _api.headers(accessToken, json: true),
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
      throw ApiException(
        'The server sent an unexpected reply. Try again.',
      );
    }
  }

  Future<void> delete(String accessToken, String id) async {
    final response = await _api.send(
      () => _api.httpClient.delete(
        _api.uri('/api/v1/api-tokens/${Uri.encodeComponent(id)}'),
        headers: _api.headers(accessToken),
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
    final response = await _api.send(
      () => _api.httpClient.get(
        _api.uri(
          '/api/v1/api-tokens/${Uri.encodeComponent(id)}/requests',
          queryParameters: {'limit': '$limit', 'before': ?before},
        ),
        headers: _api.headers(accessToken),
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
      throw ApiException(
        'The server sent an unexpected reply. Try again.',
      );
    }
  }

  // Hints contain "…": decode as UTF-8 whatever charset the reply names.
  static Map<String, dynamic> _json(http.Response response) =>
      ApiClient.json(response);

  void _check(
    http.Response response, {
    required int expected,
    required String fallback,
  }) {
    if (response.statusCode == expected) return;
    switch (response.statusCode) {
      case 404:
        throw ApiException('This token no longer exists.');
      case 400:
        throw ApiException(ApiClient.serverMessage(response) ?? fallback);
      default:
        throw ApiException(
          'Something went wrong (${response.statusCode}). Try again.',
        );
    }
  }
}
