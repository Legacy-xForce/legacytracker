import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legacytracker/src/data/network/mapbox_token_service.dart';

void main() {
  test(
    'mints a token with the session bearer and no JSON content-type',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://tracker.test/api/v1/mapbox/token',
        );
        expect(request.headers['authorization'], 'Bearer session');
        expect(request.headers.containsKey('content-type'), isFalse);
        return http.Response(
          jsonEncode({'token': 'tk.one', 'expires_at': _inOneHour()}),
          200,
        );
      });
      final service = MapboxTokenService(
        baseUrl: 'https://tracker.test',
        getAccessToken: () => 'session',
        httpClient: client,
      );

      expect(await service.token, 'tk.one');
      expect(requests, 1);
    },
  );

  test('caches the token until shortly before expiry', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(
        jsonEncode({'token': 'tk.cached', 'expires_at': _inOneHour()}),
        200,
      );
    });
    final service = MapboxTokenService(
      baseUrl: 'https://tracker.test',
      getAccessToken: () => 'session',
      httpClient: client,
    );

    expect(await service.token, 'tk.cached');
    expect(await service.token, 'tk.cached');
    expect(requests, 1);

    service.invalidate();
    expect(await service.token, 'tk.cached');
    expect(requests, 2);
  });

  test('shares one request between concurrent callers', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response(
        jsonEncode({'token': 'tk.shared', 'expires_at': _inOneHour()}),
        200,
      );
    });
    final service = MapboxTokenService(
      baseUrl: 'https://tracker.test',
      getAccessToken: () => 'session',
      httpClient: client,
    );

    final tokens = await Future.wait([service.token, service.token]);
    expect(tokens, ['tk.shared', 'tk.shared']);
    expect(requests, 1);
  });

  test('refreshes after the refresh margin', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      final value = requests == 1 ? 'tk.first' : 'tk.second';
      return http.Response(
        jsonEncode({
          'token': value,
          'expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 1))
              .toIso8601String(),
        }),
        200,
      );
    });
    final service = MapboxTokenService(
      baseUrl: 'https://tracker.test',
      getAccessToken: () => 'session',
      refreshMarginSeconds: 1,
      httpClient: client,
    );

    expect(await service.token, 'tk.first');
    // refreshAt is clamped to one second away; wait for it.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(await service.token, 'tk.second');
    expect(requests, 2);
  });

  test('returns null without a session and does not call the server', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('{}', 200);
    });
    final service = MapboxTokenService(
      baseUrl: 'https://tracker.test',
      getAccessToken: () => null,
      httpClient: client,
    );

    expect(await service.token, isNull);
    expect(requests, 0);
  });

  test('returns null on a refused request and retries next time', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('{"error":"unavailable"}', 503);
    });
    final service = MapboxTokenService(
      baseUrl: 'https://tracker.test',
      getAccessToken: () => 'session',
      httpClient: client,
    );

    expect(await service.token, isNull);
    expect(await service.token, isNull);
    expect(requests, 2);
  });

  test('returns null on malformed responses', () async {
    final client = MockClient((request) async {
      return http.Response('not json', 200);
    });
    final service = MapboxTokenService(
      baseUrl: 'https://tracker.test',
      getAccessToken: () => 'session',
      httpClient: client,
    );

    expect(await service.token, isNull);
  });

  test('falls back to the configured TTL when expires_at is missing', () async {
    final client = MockClient((request) async {
      return http.Response('{"token":"tk.noexpiry"}', 200);
    });
    final service = MapboxTokenService(
      baseUrl: 'https://tracker.test',
      getAccessToken: () => 'session',
      ttlSeconds: 3300,
      httpClient: client,
    );

    expect(await service.token, 'tk.noexpiry');
  });
}

String _inOneHour() =>
    DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String();
