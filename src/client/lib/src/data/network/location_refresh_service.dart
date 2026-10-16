import 'dart:convert';

import 'package:http/http.dart' as http;

/// A forced refresh that failed, with a message safe to show to the user.
class LocationRefreshException implements Exception {
  LocationRefreshException(this.message);

  /// What the user sees when the phone couldn't be reached.
  static const unreachableMessage =
      'Unable to reach device for location update. The device may be '
      'offline or in battery saver mode.';

  final String message;

  @override
  String toString() => message;
}

/// Asks the server to wake another user's phone for a fresh position.
class LocationRefreshService {
  LocationRefreshService({required String baseUrl, http.Client? httpClient})
    : _baseUri = Uri.parse(baseUrl),
      _httpClient = httpClient ?? http.Client();

  final Uri _baseUri;
  final http.Client _httpClient;

  /// The server answers once the phone has reported in, or after ~25 s, so
  /// the client waits a little longer than that before giving up itself.
  static const _timeout = Duration(seconds: 35);

  /// Completes once [userId]'s phone has uploaded a fresh position (it also
  /// reaches us over the realtime stream). Throws [LocationRefreshException]
  /// when it doesn't.
  Future<void> refresh(
    String accessToken,
    String userId, {
    required String name,
  }) async {
    final http.Response response;
    try {
      response = await _httpClient
          .post(
            _baseUri.replace(
              path:
                  '/api/v1/users/${Uri.encodeComponent(userId)}/location-refresh',
            ),
            headers: {'authorization': 'Bearer $accessToken'},
          )
          .timeout(_timeout);
    } on Exception {
      throw LocationRefreshException(
        'Unable to reach the server. Check your connection and try again.',
      );
    }
    if (response.statusCode == 200) return;
    if (response.statusCode == 403 && _errorCode(response) == 'not_sharing') {
      throw LocationRefreshException(
        "$name isn't sharing their location with you.",
      );
    }
    throw LocationRefreshException(LocationRefreshException.unreachableMessage);
  }

  String? _errorCode(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      return body is Map<String, dynamic> ? body['error'] as String? : null;
    } on FormatException {
      return null;
    }
  }
}
