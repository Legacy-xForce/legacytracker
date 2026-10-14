import 'dart:convert';

import 'package:http/http.dart' as http;

/// A request the server refused, with a message safe to show to the user.
class SharingException implements Exception {
  SharingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Which users the signed-in user has switched location sharing off for.
/// Sharing is on by default, so the server only tracks the exceptions.
class SharingService {
  SharingService({required String baseUrl, http.Client? httpClient})
    : _baseUri = Uri.parse(baseUrl),
      _httpClient = httpClient ?? http.Client();

  final Uri _baseUri;
  final http.Client _httpClient;

  /// Ids of the users we are not sharing our location with.
  Future<Set<String>> fetchHiddenFrom(String accessToken) async {
    final response = await _send(
      () => _httpClient.get(
        _baseUri.replace(path: '/api/v1/sharing'),
        headers: _headers(accessToken),
      ),
    );
    _check(response);
    return _parse(response);
  }

  /// Turns sharing with [viewerId] on or off; returns the updated hidden set.
  Future<Set<String>> setShared(
    String accessToken,
    String viewerId, {
    required bool enabled,
  }) async {
    final response = await _send(
      () => _httpClient.put(
        _baseUri.replace(
          path: '/api/v1/sharing/${Uri.encodeComponent(viewerId)}',
        ),
        headers: _headers(accessToken),
        body: jsonEncode({'enabled': enabled}),
      ),
    );
    _check(response);
    return _parse(response);
  }

  Set<String> _parse(http.Response response) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['hidden_from'] as List<dynamic>).cast<String>().toSet();
  }

  Map<String, String> _headers(String accessToken) => {
    'content-type': 'application/json',
    'authorization': 'Bearer $accessToken',
  };

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(const Duration(seconds: 15));
    } on Exception {
      throw SharingException(
        'Unable to reach the server. Check your connection and try again.',
      );
    }
  }

  void _check(http.Response response) {
    if (response.statusCode == 200) return;
    switch (response.statusCode) {
      case 404:
        throw SharingException('This user no longer exists.');
      default:
        throw SharingException(
          'Something went wrong (${response.statusCode}). Try again.',
        );
    }
  }
}
