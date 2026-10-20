import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/core/theme.dart';
import 'package:legacytracker/src/data/network/auth_service.dart';
import 'package:legacytracker/src/data/network/device_service.dart';
import 'package:legacytracker/src/data/network/profile_service.dart';
import 'package:legacytracker/src/features/auth/access_denied_screen.dart';
import 'package:legacytracker/src/features/auth/auth_provider.dart';

const _granted = {'calendar': true, 'tracker': true};
const _notGranted = {'calendar': true, 'tracker': false};

String _jwt(Map<String, Object> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'ES256'})}.${part(claims)}.c2ln';
}

/// An access token for alice with the given Legacy Auth scopes.
String _token(Map<String, bool> scopes) =>
    _jwt({'sub': 'user-1', 'username': 'alice', 'scopes': scopes});

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _tokenResponse(String accessToken) => _json({
  'access_token': accessToken,
  'refresh_token': 'refresh-2',
  'expires_in': 900,
  'refresh_expires_in': 2592000,
});

final _disabled = _json({'error': 'Account disabled'}, 403);

/// A signed-in session on the phone, with this install's device token.
void _storeSession(String accessToken, {required Duration expiresIn}) {
  final now = DateTime.now();
  SharedPreferences.setMockInitialValues({
    'auth_username': 'alice',
    'auth_access_token': accessToken,
    'auth_refresh_token': 'refresh-1',
    'auth_expires_at': now.add(expiresIn).millisecondsSinceEpoch,
    'auth_refresh_expires_at': now
        .add(const Duration(days: 30))
        .millisecondsSinceEpoch,
    'lt_device_id': 'device-1',
    'lt_device_token': 'device-secret',
    'lt_device_user': 'user-1',
  });
}

/// An [AuthProvider] against a fake Legacy Auth ([authServer]) and a tracker
/// server that serves alice's profile. Every request lands in `requests`.
({AuthProvider auth, List<String> requests}) _provider(
  Future<http.Response> Function(http.Request request) authServer,
) {
  final requests = <String>[];
  MockClient recorded(MockClientHandler handler) => MockClient((request) {
    requests.add('${request.method} ${request.url.path}');
    return handler(request);
  });
  final auth = AuthProvider(
    authService: AuthService(
      baseUrl: 'https://auth.example',
      httpClient: recorded(authServer),
    ),
    profileService: ProfileService(
      baseUrl: 'https://tracker.example',
      httpClient: recorded((_) async => _json({'id': 'user-1', 'name': 'Alice'})),
    ),
    deviceService: DeviceService(
      baseUrl: 'https://tracker.example',
      httpClient: recorded((_) async => _json({'revoked': true})),
    ),
  );
  return (auth: auth, requests: requests);
}

Future<void> _initialized(AuthProvider auth) async {
  for (var i = 0; i < 100 && auth.isInitializing; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(auth.isInitializing, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthService.refresh', () {
    AuthService service(http.Response response) => AuthService(
      baseUrl: 'https://auth.example',
      httpClient: MockClient((_) async => response),
    );

    test('a disabled account ends the session and says why', () async {
      await expectLater(
        service(_disabled).refresh('refresh-1'),
        throwsA(
          allOf(
            isA<AccountDisabledException>(),
            isA<AuthRejectedException>(),
          ),
        ),
      );
    });

    test('other refusals are plain rejections', () async {
      await expectLater(
        service(_json({'error': 'Invalid refresh token'}, 401)).refresh('x'),
        throwsA(
          allOf(
            isA<AuthRejectedException>(),
            isNot(isA<AccountDisabledException>()),
          ),
        ),
      );
    });
  });

  group('AuthProvider access', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('signing in without the tracker scope explains instead of loading the map', () async {
      final (:auth, :requests) = _provider(
        (_) async => _tokenResponse(_token(_notGranted)),
      );
      await _initialized(auth);

      await auth.login('alice', 'secret');

      expect(auth.isAuthenticated, isTrue);
      expect(auth.accessDenial, AccessDenial.missingScope);
      expect(auth.username, 'alice');
      // The tracker server would refuse it anyway.
      expect(requests, isNot(contains('GET /api/v1/profile')));
    });

    test('signing in with the tracker scope grants access', () async {
      final (:auth, :requests) = _provider(
        (_) async => _tokenResponse(_token(_granted)),
      );
      await _initialized(auth);

      await auth.login('alice', 'secret');

      expect(auth.accessDenial, isNull);
      expect(auth.profile!.id, 'user-1');
    });

    test('a disabled account is explained by name, until switching account', () async {
      final (:auth, requests: _) = _provider((_) async => _disabled);
      await _initialized(auth);

      await expectLater(
        auth.login(' alice ', 'secret'),
        throwsA(isA<AccountDisabledException>()),
      );

      expect(auth.isAuthenticated, isFalse);
      expect(auth.accessDenial, AccessDenial.accountDisabled);
      expect(auth.username, 'alice');

      await auth.logout();
      expect(auth.accessDenial, isNull);
      expect(auth.username, isNull);
    });

    test('a stored session without the scope is re-checked at launch, and again on request', () async {
      _storeSession(_token(_notGranted), expiresIn: const Duration(minutes: 10));
      var refreshes = 0;
      final (:auth, :requests) = _provider((request) async {
        expect(request.url.path, '/auth/refresh');
        refreshes++;
        // Granted by an administrator between the two checks.
        return _tokenResponse(_token(refreshes == 1 ? _notGranted : _granted));
      });
      await _initialized(auth);

      // Renewed although the token was still valid: only a new token can
      // carry a newly granted scope.
      expect(refreshes, 1);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.accessDenial, AccessDenial.missingScope);

      expect(await auth.retryAccess(), isTrue);
      expect(refreshes, 2);
      expect(auth.accessDenial, isNull);
      expect(auth.profile!.id, 'user-1');
      expect(requests, contains('GET /api/v1/profile'));
    });

    test('checking again without the scope stays on the explanation', () async {
      _storeSession(_token(_notGranted), expiresIn: const Duration(minutes: 10));
      final (:auth, requests: _) = _provider(
        (_) async => _tokenResponse(_token(_notGranted)),
      );
      await _initialized(auth);

      expect(await auth.retryAccess(), isFalse);
      expect(auth.accessDenial, AccessDenial.missingScope);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.isLoading, isFalse);
    });

    test('losing the scope stops location sharing on this phone', () async {
      _storeSession(_token(_granted), expiresIn: const Duration(minutes: -1));
      final (:auth, :requests) = _provider(
        (_) async => _tokenResponse(_token(_notGranted)),
      );
      await _initialized(auth);

      expect(auth.accessDenial, AccessDenial.missingScope);
      expect(requests, contains('DELETE /api/v1/devices/device-1'));
      final prefs = await SharedPreferences.getInstance();
      expect(DeviceCredentialStore.load(prefs), isNull);
      // The session itself is kept, to check again later.
      expect(prefs.getString('auth_refresh_token'), 'refresh-2');
    });

    test('an account disabled since the last launch is signed out and explained', () async {
      _storeSession(_token(_granted), expiresIn: const Duration(minutes: -1));
      final (:auth, :requests) = _provider((_) async => _disabled);
      await _initialized(auth);

      expect(auth.isAuthenticated, isFalse);
      expect(auth.accessDenial, AccessDenial.accountDisabled);
      expect(auth.username, 'alice');
      expect(requests, contains('DELETE /api/v1/devices/device-1'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_access_token'), isNull);
    });

    test('an account disabled while waiting for the scope is explained', () async {
      _storeSession(_token(_notGranted), expiresIn: const Duration(minutes: 10));
      var refreshes = 0;
      final (:auth, requests: _) = _provider((_) async {
        refreshes++;
        return refreshes == 1 ? _tokenResponse(_token(_notGranted)) : _disabled;
      });
      await _initialized(auth);

      expect(await auth.retryAccess(), isFalse);
      expect(auth.accessDenial, AccessDenial.accountDisabled);
      expect(auth.isAuthenticated, isFalse);
    });
  });

  group('access screens', () {
    setUp(() {
      // A phone, rather than the default 800×600 landscape surface.
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.physicalSize = const Size(1080, 2400);
      view.devicePixelRatio = 2.75;
      addTearDown(view.reset);
    });

    Widget host(AuthProvider auth, Widget screen) =>
        ChangeNotifierProvider<AuthProvider>.value(
          value: auth,
          child: MaterialApp(theme: buildThemeFor(AppThemeId.teal), home: screen),
        );

    testWidgets('the scope screen names the account and the scope, and reports a failed re-check', (tester) async {
      _storeSession(_token(_notGranted), expiresIn: const Duration(minutes: 10));
      final (:auth, requests: _) = _provider(
        (_) async => _tokenResponse(_token(_notGranted)),
      );
      await tester.runAsync(() => _initialized(auth));

      await tester.pumpWidget(host(auth, const MissingScopeScreen()));

      expect(find.text('Scope Required'), findsOneWidget);
      expect(find.text('INSUFFICIENT PERMISSIONS'), findsOneWidget);
      expect(find.textContaining('(alice)'), findsOneWidget);
      expect(find.text('tracker'), findsOneWidget);

      await tester.tap(find.text('Check Again'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('Still no tracker access'), findsOneWidget);
    });

    testWidgets('both screens fit at large text sizes', (tester) async {
      _storeSession(_token(_notGranted), expiresIn: const Duration(minutes: 10));
      final (:auth, requests: _) = _provider(
        (_) async => _tokenResponse(_token(_notGranted)),
      );
      await tester.runAsync(() => _initialized(auth));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      for (final screen in const [MissingScopeScreen(), AccountDisabledScreen()]) {
        await tester.pumpWidget(host(auth, screen));
        final scaler = MediaQuery.textScalerOf(tester.element(find.byType(Scaffold)));
        expect(scaler.scale(10), 20);
        // An overflow would have failed the pump.
        expect(find.byType(OutlinedButton), findsOneWidget);
      }
    });

    testWidgets('the disabled screen leads back to signing in', (tester) async {
      final (:auth, requests: _) = _provider((_) async => _disabled);
      await tester.runAsync(() async {
        await _initialized(auth);
        await expectLater(auth.login('alice', 'secret'), throwsA(anything));
      });

      await tester.pumpWidget(host(auth, const AccountDisabledScreen()));

      expect(find.text('Access Restricted'), findsOneWidget);
      expect(find.textContaining('(alice)'), findsOneWidget);
      expect(find.text('Check Again'), findsNothing);

      await tester.tap(find.text('Switch Account / Sign In'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(auth.accessDenial, isNull);
      expect(auth.username, isNull);
    });
  });
}
