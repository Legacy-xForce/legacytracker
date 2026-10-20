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

/// Creates, lists, rotates and deletes the user's personal API tokens. These
/// calls need the signed-in session's access token; API tokens themselves
/// can't manage tokens.
class ApiTokenService {
  ApiTokenService({required String baseUrl, http.Client? httpClient})
    : _baseUri = Uri.parse(baseUrl),
      _httpClient = httpClient ?? http.Client();

  final Uri _baseUri;
  final http.Client _httpClient;

  Future<List<ApiToken>> list(String accessToken) async {
    final response = await _send(
      () => _httpClient.get(
        _uri('/api/v1/api-tokens'),
        headers: _headers(accessToken),
      ),
    );
    _check(response, expected: 200);
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
    _check(response, expected: 201);
    return _issued(response);
  }

  Future<IssuedApiToken> rotate(String accessToken, String id) async {
    final response = await _send(
      () => _httpClient.post(
        _uri('/api/v1/api-tokens/${Uri.encodeComponent(id)}/rotate'),
        headers: _headers(accessToken),
      ),
    );
    _check(response, expected: 200);
    return _issued(response);
  }

  Future<void> delete(String accessToken, String id) async {
    final response = await _send(
      () => _httpClient.delete(
        _uri('/api/v1/api-tokens/${Uri.encodeComponent(id)}'),
        headers: _headers(accessToken),
      ),
    );
    _check(response, expected: 200);
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

  Uri _uri(String path) => _baseUri.replace(path: path);

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

  void _check(http.Response response, {required int expected}) {
    if (response.statusCode == expected) return;
    switch (response.statusCode) {
      case 404:
        throw ApiTokenException('This token no longer exists.');
      case 400:
        throw ApiTokenException(
          _serverMessage(response) ?? 'The token could not be created.',
        );
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
