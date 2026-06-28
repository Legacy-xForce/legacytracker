import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/notification_model.dart';
import '../models/user_model.dart';

class ProfileService {
  ProfileService({required String baseUrl, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _baseUri = Uri.parse(baseUrl);

  final Uri _baseUri;
  final http.Client _httpClient;

  Future<UserProfile> fetchProfile(String accessToken) async {
    final response = await _httpClient
        .get(_apiUri('/api/v1/profile'), headers: _bearerHeaders(accessToken))
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception(
              'Unable to reach the server. Check your connection and try again.',
            );
          },
        );

    if (response.statusCode != 200) {
      throw Exception('Unable to fetch profile: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return UserProfile(
      id: data['id'] as String,
      name: data['name'] as String,
      avatarUrl: data['avatar_url'] as String? ?? '',
      locationTrackingPaused:
          data['location_tracking_paused'] as bool? ?? false,
      missingPermissions: data['missing_permissions'] as bool? ?? false,
      batterySavingEnabled: data['battery_saving_enabled'] as bool? ?? false,
      batteryLevel: (data['battery_level'] as num?)?.toInt(),
      isCharging: data['is_charging'] as bool?,
      history: [],
    );
  }

  Future<UserProfile> updateProfile(
    String accessToken, {
    String? name,
    String? avatarUrl,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) {
      body['name'] = name;
    }
    if (avatarUrl != null) {
      body['avatar_url'] = avatarUrl;
    }

    if (body.isEmpty) {
      throw Exception('No profile changes provided');
    }

    final response = await _httpClient.patch(
      _apiUri('/api/v1/profile'),
      headers: {
        'content-type': 'application/json',
        ..._bearerHeaders(accessToken),
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw Exception('Unable to update profile: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return UserProfile(
      id: data['id'] as String,
      name: data['name'] as String,
      avatarUrl: data['avatar_url'] as String? ?? '',
      locationTrackingPaused:
          data['location_tracking_paused'] as bool? ?? false,
      missingPermissions: data['missing_permissions'] as bool? ?? false,
      batterySavingEnabled: data['battery_saving_enabled'] as bool? ?? false,
      batteryLevel: (data['battery_level'] as num?)?.toInt(),
      isCharging: data['is_charging'] as bool?,
      history: [],
    );
  }

  Future<List<NotificationItem>> fetchNotifications(String accessToken) async {
    final response = await _httpClient
        .get(
          _apiUri('/api/v1/notifications'),
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
      throw Exception('Unable to load notifications: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = List<Map<String, dynamic>>.from(
      data['notifications'] as List<dynamic>,
    );
    return list.map(NotificationItem.fromJson).toList();
  }

  Future<void> markNotificationRead(
    String accessToken,
    int notificationId,
  ) async {
    final response = await _httpClient.post(
      _apiUri('/api/v1/notifications/read'),
      headers: {
        'content-type': 'application/json',
        ..._bearerHeaders(accessToken),
      },
      body: jsonEncode({'notification_id': notificationId}),
    );

    if (response.statusCode != 200) {
      throw Exception('Unable to update notification: ${response.body}');
    }
  }

  Uri _apiUri(String path) {
    return _baseUri.replace(path: path);
  }

  Map<String, String> _bearerHeaders(String accessToken) {
    return {'authorization': 'Bearer $accessToken'};
  }
}
