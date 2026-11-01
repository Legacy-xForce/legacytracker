import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_client.dart';

/// Tells the server which FCM token this phone can be reached on, so it can
/// push tracking commands. Best effort: a failure only means pushes won't
/// arrive until the next registration.
Future<void> registerFcmToken({
  required String baseUrl,
  required String accessToken,
  required String token,
  http.Client? httpClient,
}) async {
  final api = ApiClient(baseUrl: baseUrl, httpClient: httpClient);
  try {
    await api.send(
      () => api.httpClient.post(
        api.uri('/api/v1/fcm-token'),
        headers: api.headers(accessToken, json: true),
        body: jsonEncode({'token': token}),
      ),
    );
  } on ApiException {
    // Non-critical.
  } finally {
    if (httpClient == null) api.close();
  }
}
