import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/location_session.dart';

/// The user whose history was requested has switched off sharing with us.
class NotSharingException implements Exception {
  const NotSharingException();

  @override
  String toString() => "This user isn't sharing their location with you.";
}

class HistoryService {
  HistoryService({required String baseUrl, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _baseUri = Uri.parse(baseUrl);

  final Uri _baseUri;
  final http.Client _httpClient;

  Future<List<LocationSession>> fetchHistory(
    String accessToken, {
    required String userId,
    required DateTime from,
    required DateTime to,
    bool includePoints = true,
  }) async {
    final response = await _httpClient
        .get(
          _apiUri('/api/v1/history', {
            'user_id': userId,
            'from': from.toUtc().toIso8601String(),
            'to': to.toUtc().toIso8601String(),
            if (!includePoints) 'points': 'false',
          }),
          headers: _bearerHeaders(accessToken),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception(
              'Unable to reach the server. Check your connection and try again.',
            );
          },
        );

    if (response.statusCode == 403 &&
        response.body.contains('"not_sharing"')) {
      throw const NotSharingException();
    }
    if (response.statusCode != 200) {
      throw Exception('Unable to fetch history: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final sessions = List<Map<String, dynamic>>.from(
      data['sessions'] as List<dynamic>,
    );
    return sessions.map(LocationSession.fromJson).toList();
  }

  /// Erases the signed-in user's own stored points from [from] to [to] (both
  /// inclusive) and returns how many were removed. A trip is its start..end
  /// window, a day is the whole day. Nobody else's history can be deleted, so
  /// there is no user to name.
  Future<int> deleteHistory(
    String accessToken, {
    required DateTime from,
    required DateTime to,
  }) async {
    final response = await _httpClient
        .delete(
          _apiUri('/api/v1/history', {
            'from': from.toUtc().toIso8601String(),
            'to': to.toUtc().toIso8601String(),
          }),
          headers: _bearerHeaders(accessToken),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception(
              'Unable to reach the server. Check your connection and try again.',
            );
          },
        );

    if (response.statusCode != 200) {
      throw Exception('Unable to delete history: ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['deleted'] as num?)?.toInt() ?? 0;
  }

  Uri _apiUri(String path, Map<String, String> queryParams) {
    return _baseUri.replace(path: path, queryParameters: queryParams);
  }

  Map<String, String> _bearerHeaders(String accessToken) {
    return {'authorization': 'Bearer $accessToken'};
  }
}
