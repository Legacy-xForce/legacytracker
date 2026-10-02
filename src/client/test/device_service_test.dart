import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/data/network/device_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('register exchanges the session JWT for a device token', () async {
    late http.Request sent;
    final service = DeviceService(
      baseUrl: 'https://tracker.example',
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({'device_id': 'dev-1', 'device_token': 'secret'}),
          200,
        );
      }),
    );

    final credentials = await service.register(
      'jwt-token',
      userId: 'user-1',
      platform: 'android',
      replaces: 'dev-0',
    );

    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/v1/devices');
    expect(sent.headers['authorization'], 'Bearer jwt-token');
    expect(jsonDecode(sent.body), {'platform': 'android', 'replaces': 'dev-0'});
    expect(credentials.deviceId, 'dev-1');
    expect(credentials.userId, 'user-1');
    expect(credentials.authHeader, 'Device secret');
  });

  test('register omits replaces on first registration', () async {
    late http.Request sent;
    final service = DeviceService(
      baseUrl: 'https://tracker.example',
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({'device_id': 'dev-1', 'device_token': 'secret'}),
          200,
        );
      }),
    );
    await service.register('jwt', userId: 'u', platform: 'ios');
    expect(jsonDecode(sent.body), {'platform': 'ios'});
  });

  test('register surfaces server errors (older servers lack the route)', () {
    final service = DeviceService(
      baseUrl: 'https://tracker.example',
      httpClient: MockClient((_) async => http.Response('Not found', 404)),
    );
    expect(
      service.register('jwt', userId: 'u', platform: 'android'),
      throwsException,
    );
  });

  test('unregister revokes with the device token itself', () async {
    late http.Request sent;
    final service = DeviceService(
      baseUrl: 'https://tracker.example',
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response('{"revoked":true}', 200);
      }),
    );
    await service.unregister(
      const DeviceCredentials(deviceId: 'dev-1', token: 'secret', userId: 'u'),
    );
    expect(sent.method, 'DELETE');
    expect(sent.url.path, '/api/v1/devices/dev-1');
    expect(sent.headers['authorization'], 'Device secret');
  });

  test('credential store round-trips and clears', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(DeviceCredentialStore.load(prefs), isNull);

    await DeviceCredentialStore.save(
      prefs,
      const DeviceCredentials(deviceId: 'd', token: 't', userId: 'u'),
    );
    final loaded = DeviceCredentialStore.load(prefs)!;
    expect((loaded.deviceId, loaded.token, loaded.userId), ('d', 't', 'u'));

    await DeviceCredentialStore.clear(prefs);
    expect(DeviceCredentialStore.load(prefs), isNull);
  });
}
