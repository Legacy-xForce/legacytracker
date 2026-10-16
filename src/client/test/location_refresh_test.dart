import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legacytracker/src/data/network/location_refresh_service.dart';

LocationRefreshService serviceFor(
  Future<http.Response> Function(http.Request) handler,
) => LocationRefreshService(
  baseUrl: 'https://example.test',
  httpClient: MockClient(handler),
);

Future<void> refresh(LocationRefreshService service) =>
    service.refresh('token', 'bob-id', name: 'Bob');

void main() {
  test('posts to the user\'s refresh endpoint with the access token', () async {
    final service = serviceFor((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/users/bob-id/location-refresh');
      expect(request.headers['authorization'], 'Bearer token');
      return http.Response(jsonEncode({'user_id': 'bob-id'}), 200);
    });
    await refresh(service);
  });

  for (final status in [504, 409]) {
    test('HTTP $status says the device could not be reached', () async {
      final service = serviceFor(
        (_) async =>
            http.Response(jsonEncode({'error': 'device_unreachable'}), status),
      );
      await expectLater(
        refresh(service),
        throwsA(
          isA<LocationRefreshException>().having(
            (e) => e.message,
            'message',
            LocationRefreshException.unreachableMessage,
          ),
        ),
      );
    });
  }

  test('says so when they stopped sharing with us', () async {
    final service = serviceFor(
      (_) async => http.Response(jsonEncode({'error': 'not_sharing'}), 403),
    );
    await expectLater(
      refresh(service),
      throwsA(
        isA<LocationRefreshException>().having(
          (e) => e.message,
          'message',
          "Bob isn't sharing their location with you.",
        ),
      ),
    );
  });

  test('a connection failure is reported, not thrown raw', () async {
    final service = serviceFor((_) async => throw http.ClientException('down'));
    await expectLater(
      refresh(service),
      throwsA(
        isA<LocationRefreshException>().having(
          (e) => e.message,
          'message',
          contains('Unable to reach the server'),
        ),
      ),
    );
  });
}
