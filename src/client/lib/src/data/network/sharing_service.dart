import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_client.dart';

/// Which users the signed-in user has switched location sharing off for.
/// Sharing is on by default, so the server only tracks the exceptions.
class SharingService {
  SharingService({required String baseUrl, http.Client? httpClient})
    : _api = ApiClient(baseUrl: baseUrl, httpClient: httpClient);

  final ApiClient _api;

  /// Ids of the users we are not sharing our location with.
  Future<Set<String>> fetchHiddenFrom(String accessToken) async {
    final response = await _api.send(
      () => _api.httpClient.get(
        _api.uri('/api/v1/sharing'),
        headers: _api.headers(accessToken),
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
    final response = await _api.send(
      () => _api.httpClient.put(
        _api.uri('/api/v1/sharing/${Uri.encodeComponent(viewerId)}'),
        headers: _api.headers(accessToken, json: true),
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

  void _check(http.Response response) {
    if (response.statusCode == 200) return;
    switch (response.statusCode) {
      case 404:
        throw ApiException('This user no longer exists.');
      default:
        throw ApiException(
          'Something went wrong (${response.statusCode}). Try again.',
        );
    }
  }
}
