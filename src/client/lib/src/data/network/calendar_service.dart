import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/calendar_event.dart';

class CalendarException implements Exception {
  CalendarException(this.message, {this.noAccess = false});

  final String message;

  /// The calendar refused the token (401/403): the account has no calendar
  /// access. Not an error to show; the overlay just isn't offered.
  final bool noAccess;

  @override
  String toString() => message;
}

/// Reads events from Legacy Calendar with the tracker's own access token.
class CalendarService {
  CalendarService({required String baseUrl, http.Client? httpClient})
    : _baseUri = Uri.parse(baseUrl),
      _httpClient = httpClient ?? http.Client();

  final Uri _baseUri;
  final http.Client _httpClient;

  /// Events overlapping [from]..[to]. `/events/upcoming` isn't used: it says
  /// nothing about events that have already started but not ended.
  Future<List<CalendarEvent>> list(
    String accessToken, {
    required DateTime from,
    required DateTime to,
  }) async {
    final http.Response response;
    try {
      response = await _httpClient
          .get(
            _baseUri.replace(
              path: '/events',
              queryParameters: {
                'start': from.toUtc().toIso8601String(),
                'end': to.toUtc().toIso8601String(),
              },
            ),
            headers: {'authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 15));
    } on Exception {
      throw CalendarException('Unable to reach the calendar.');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw CalendarException('No calendar access.', noAccess: true);
    }
    if (response.statusCode != 200) {
      throw CalendarException('Calendar error (${response.statusCode}).');
    }
    try {
      final items = jsonDecode(response.body) as List<dynamic>;
      return [
        for (final item in items)
          if (item is Map<String, dynamic>) ?CalendarEvent.tryParse(item),
      ];
    } on Object {
      throw CalendarException('Unexpected calendar response.');
    }
  }
}
