import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/leaderboard_entry.dart';

class LeaderboardService {
  LeaderboardService({required String baseUrl, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _baseUri = Uri.parse(baseUrl);

  final Uri _baseUri;
  final http.Client _httpClient;

  /// Who travelled furthest between [from] and [to], furthest first.
  Future<List<LeaderboardEntry>> fetch(
    String accessToken, {
    required DateTime from,
    required DateTime to,
  }) async {
    final response = await _httpClient
        .get(
          _baseUri.replace(
            path: '/api/v1/leaderboard',
            queryParameters: {
              'from': from.toUtc().toIso8601String(),
              'to': to.toUtc().toIso8601String(),
            },
          ),
          headers: {'authorization': 'Bearer $accessToken'},
        )
        .timeout(
          // Every trip in the period is rebuilt server-side; a long custom
          // range takes a moment.
          const Duration(seconds: 20),
          onTimeout: () {
            throw Exception(
              'Unable to reach the server. Check your connection and try again.',
            );
          },
        );

    if (response.statusCode != 200) {
      throw Exception('Unable to fetch the leaderboard: ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return [
      for (final raw in data['entries'] as List<dynamic>? ?? const [])
        ?LeaderboardEntry.fromJson(raw as Map<String, dynamic>),
    ];
  }
}
