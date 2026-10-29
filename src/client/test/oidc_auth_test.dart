import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/data/network/auth_service.dart';
import 'package:legacytracker/src/data/network/oidc_service.dart';
import 'package:legacytracker/src/data/network/profile_service.dart';
import 'package:legacytracker/src/data/storage/token_storage.dart';
import 'package:legacytracker/src/features/auth/auth_provider.dart';
import 'package:legacytracker/src/features/auth/token_manager.dart';

const _issuer = 'https://auth.example';
const _redirect = 'com.legacy.legacytracker:/oauth2redirect';

String _b64(Object value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

String _jwt(Map<String, Object?> claims) =>
    '${_b64({'alg': 'ES256'})}.${_b64(claims)}.sig';

String _access({bool calendar = true, String aud = 'tracker'}) => _jwt({
  'sub': 'user-1',
  'username': 'ada',
  'aud': aud,
  'scopes': {'tracker': true, 'calendar': calendar},
});

String _idToken(String nonce, {String aud = 'tracker-mobile'}) => _jwt({
  'iss': _issuer,
  'aud': aud,
  'sub': 'user-1',
  'nonce': nonce,
  'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
});

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// A fake Legacy Auth: discovery, a token endpoint whose refresh tokens rotate
/// (only the newest works, like the OP's), and the legacy `/auth/refresh`.
class _FakeOp {
  _FakeOp({this.calendar = true});

  bool calendar;
  String current = 'rt-0';
  int issued = 0;
  final List<Map<String, String>> tokenRequests = [];
  String? nonce;
  Future<http.Response> Function(Map<String, String>)? override;
  bool offline = false;

  late final client = MockClient((request) async {
    if (offline) throw http.ClientException('offline');
    final path = request.url.path;
    if (path == '/.well-known/openid-configuration') {
      return _json({
        'issuer': _issuer,
        'authorization_endpoint': '$_issuer/authorize',
        'token_endpoint': '$_issuer/token',
        'end_session_endpoint': '$_issuer/logout',
      });
    }
    if (path == '/token') {
      final form = request.bodyFields;
      tokenRequests.add(form);
      if (override case final handler?) return handler(form);
      return _grant(form);
    }
    throw StateError('unexpected $path');
  });

  http.Response _grant(Map<String, String> form) {
    if (form['grant_type'] == 'refresh_token' &&
        form['refresh_token'] != current) {
      return _json({'error': 'invalid_grant'}, 400);
    }
    current = 'rt-${++issued}';
    final forCalendar = form['resource'] == calendarResource;
    return _json({
      'access_token': forCalendar
          ? _access(aud: 'calendar')
          : _access(calendar: calendar),
      'refresh_token': current,
      'token_type': 'Bearer',
      'expires_in': 900,
      if (form['grant_type'] == 'authorization_code') 'id_token': _idToken(nonce!),
    });
  }

  OidcService service() => OidcService(
    issuer: _issuer,
    clientId: 'tracker-mobile',
    redirectUri: _redirect,
    postLogoutRedirectUri: 'com.legacy.legacytracker:/logout',
    httpClient: client,
  );
}

/// What the browser comes back with once the OP accepts [url].
String _callbackFor(Uri url, {String? error, String? state, String? iss}) {
  final query = url.queryParameters;
  return Uri.parse(_redirect).replace(queryParameters: {
    if (error != null) 'error': error else 'code': 'the-code',
    'state': state ?? query['state']!,
    'iss': iss ?? _issuer,
  }).toString();
}

Future<TokenStorage> _storage() async =>
    TokenStorage(await SharedPreferences.getInstance());

/// A keychain that can be told to fail a write, like an iOS keychain while the
/// phone is locked.
class _SaveFailingStorage extends TokenStorage {
  _SaveFailingStorage(super.prefs);

  bool failNextSave = false;

  @override
  Future<void> saveGrant(StoredGrant grant) {
    if (failNextSave) {
      failNextSave = false;
      throw Exception('Keychain unavailable');
    }
    return super.saveGrant(grant);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('OidcService', () {
    test('asks for one grant covering both apps, with PKCE', () async {
      final request = await _FakeOp().service().authorizationRequest(
        withCalendar: true,
      );
      final url = request.url;

      expect(url.toString(), startsWith('$_issuer/authorize?'));
      expect(url.queryParametersAll['resource'], [
        trackerResource,
        calendarResource,
      ]);
      expect(
        url.queryParameters['scope'],
        'openid profile offline_access tracker.read tracker.write calendar.read',
      );
      expect(url.queryParameters['client_id'], 'tracker-mobile');
      expect(url.queryParameters['redirect_uri'], _redirect);
      expect(url.queryParameters['prompt'], 'consent');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      final challenge = base64Url
          .encode(sha256.convert(ascii.encode(request.codeVerifier)).bytes)
          .replaceAll('=', '');
      expect(url.queryParameters['code_challenge'], challenge);
    });

    test('leaves the calendar out when told to', () async {
      final request = await _FakeOp().service().authorizationRequest(
        withCalendar: false,
      );
      expect(request.url.queryParametersAll['resource'], [trackerResource]);
      expect(request.url.queryParameters['scope'], isNot(contains('calendar')));
    });

    test('exchanges the code for a tracker token', () async {
      final op = _FakeOp();
      final oidc = op.service();
      final request = await oidc.authorizationRequest(withCalendar: true);
      op.nonce = request.nonce;

      final tokens = await oidc.exchangeCode(
        request,
        Uri.parse(_callbackFor(request.url)),
      );

      expect(tokens.refreshToken, 'rt-1');
      expect(tokens.idToken, isNotNull);
      expect(op.tokenRequests.single, {
        'grant_type': 'authorization_code',
        'code': 'the-code',
        'redirect_uri': _redirect,
        'code_verifier': request.codeVerifier,
        'resource': trackerResource,
        'client_id': 'tracker-mobile',
      });
    });

    test('refuses an answer that is not for this sign-in', () async {
      final op = _FakeOp();
      final oidc = op.service();
      final request = await oidc.authorizationRequest(withCalendar: true);
      op.nonce = 'another-nonce';

      for (final callback in [
        _callbackFor(request.url, state: 'forged'),
        _callbackFor(request.url, iss: 'https://evil.example'),
        _callbackFor(request.url), // ID token with the wrong nonce
      ]) {
        await expectLater(
          oidc.exchangeCode(request, Uri.parse(callback)),
          throwsA(isA<AuthException>()),
        );
      }
    });

    test('reports a denied sign-in and whether the calendar was asked for', () async {
      final oidc = _FakeOp().service();
      final request = await oidc.authorizationRequest(withCalendar: true);

      await expectLater(
        oidc.exchangeCode(
          request,
          Uri.parse(_callbackFor(request.url, error: 'access_denied')),
        ),
        throwsA(
          isA<SignInDeniedException>().having(
            (e) => e.calendarRequested,
            'calendarRequested',
            true,
          ),
        ),
      );
    });

    test('a refused refresh is a rejection, not a network error', () async {
      final oidc = _FakeOp().service();
      await expectLater(
        oidc.refresh('stale', trackerResource),
        throwsA(isA<AuthRejectedException>()),
      );
    });

    test('throttling is transient, not a rejection', () async {
      final op = _FakeOp();
      op.override = (_) async =>
          _json({'error': 'temporarily_unavailable'}, 429);

      await expectLater(
        op.service().refresh('rt-0', trackerResource),
        throwsA(allOf(isA<AuthException>(), isNot(isA<AuthRejectedException>()))),
      );
    });

    test('a proxy error page is transient, not a rejection', () async {
      final op = _FakeOp();
      op.override = (_) async => http.Response('<html>blocked</html>', 403);

      await expectLater(
        op.service().refresh('rt-0', trackerResource),
        throwsA(allOf(isA<AuthException>(), isNot(isA<AuthRejectedException>()))),
      );
    });

    test('signs out at the OP with the ID token as hint', () async {
      final url = await _FakeOp().service().endSessionUrl('id-token');
      expect(url.toString(), startsWith('$_issuer/logout?'));
      expect(url.queryParameters, {
        'client_id': 'tracker-mobile',
        'post_logout_redirect_uri': 'com.legacy.legacytracker:/logout',
        'id_token_hint': 'id-token',
      });
    });
  });

  group('TokenManager', () {
    Future<TokenManager> signedIn(_FakeOp op, {bool calendar = true}) async {
      final tokens = TokenManager(
        oidc: op.service(),
        legacyAuth: AuthService(baseUrl: _issuer, httpClient: op.client),
        storage: await _storage(),
      );
      await tokens.load();
      await tokens.adoptSignIn(
        OidcTokens(
          accessToken: _access(calendar: op.calendar),
          refreshToken: op.current,
          expiresAt: DateTime.now().add(const Duration(minutes: 15)),
          idToken: 'id-token',
        ),
        calendar: calendar,
      );
      return tokens;
    }

    test('stores the grant securely and keeps access tokens in memory', () async {
      final op = _FakeOp();
      await signedIn(op);

      final grant = await (await _storage()).loadGrant();
      expect(grant?.refreshToken, 'rt-0');
      expect(grant?.userId, 'user-1');
      expect(grant?.username, 'ada');
      expect(grant?.idToken, 'id-token');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
    });

    test('never refreshes twice with the same token', () async {
      final op = _FakeOp();
      final tokens = await signedIn(op);

      await Future.wait([
        tokens.refreshTracker(force: true),
        tokens.refreshCalendar(),
        tokens.refreshTracker(force: true),
      ]);

      expect(op.tokenRequests.map((r) => r['refresh_token']), [
        'rt-0',
        'rt-1',
        'rt-2',
      ]);
      expect((await (await _storage()).loadGrant())?.refreshToken, 'rt-3');
    });

    test('gets the calendar token from the same grant', () async {
      final op = _FakeOp();
      final tokens = await signedIn(op);

      expect(tokens.mayUseCalendar, isTrue);
      await tokens.refreshCalendar();

      expect(op.tokenRequests.single['resource'], calendarResource);
      expect(jwtClaims(tokens.calendarAccessToken)?['aud'], 'calendar');
      // Cached while fresh.
      await tokens.refreshCalendar();
      expect(op.tokenRequests, hasLength(1));
    });

    test('does not ask for a calendar the account does not have', () async {
      final op = _FakeOp(calendar: false);
      final tokens = await signedIn(op);

      await tokens.refreshCalendar();

      expect(tokens.mayUseCalendar, isFalse);
      expect(tokens.calendarAccessToken, isNull);
      expect(op.tokenRequests, isEmpty);
    });

    test('does not ask when the grant left the calendar out', () async {
      final op = _FakeOp();
      final tokens = await signedIn(op, calendar: false);

      await tokens.refreshCalendar();

      expect(tokens.calendarAccessToken, isNull);
      expect(op.tokenRequests, isEmpty);
    });

    test('a calendar refusal hides the calendar, not the session', () async {
      final op = _FakeOp();
      final tokens = await signedIn(op);
      op.override = (form) async => _json({'error': 'invalid_target'}, 400);

      await tokens.refreshCalendar();

      expect(tokens.mayUseCalendar, isFalse);
      expect(tokens.hasSession, isTrue);
    });

    test('a network failure keeps the grant', () async {
      final op = _FakeOp();
      final tokens = await signedIn(op);
      op.offline = true;

      await expectLater(
        tokens.refreshTracker(force: true),
        throwsA(isA<AuthException>()),
      );
      expect((await (await _storage()).loadGrant())?.refreshToken, 'rt-0');
    });

    test('a rotated token is kept even when it cannot be stored', () async {
      final op = _FakeOp();
      final storage = _SaveFailingStorage(
        await SharedPreferences.getInstance(),
      );
      final tokens = TokenManager(
        oidc: op.service(),
        legacyAuth: AuthService(baseUrl: _issuer, httpClient: op.client),
        storage: storage,
      );
      await tokens.load();
      await tokens.adoptSignIn(
        OidcTokens(
          accessToken: _access(),
          refreshToken: 'rt-0',
          expiresAt: DateTime.now().add(const Duration(minutes: 15)),
          idToken: 'id-token',
        ),
        calendar: true,
      );

      storage.failNextSave = true;
      await tokens.refreshTracker(force: true); // rt-0 -> rt-1, not persisted
      await tokens.refreshTracker(force: true); // must present rt-1, not rt-0

      expect(op.tokenRequests.map((r) => r['refresh_token']), ['rt-0', 'rt-1']);
      expect(tokens.hasSession, isTrue);
    });

    test('a legacy session keeps refreshing through /auth/refresh', () async {
      final legacyAccess = _access();
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.url.path);
        return _json({
          'access_token': legacyAccess,
          'refresh_token': 'legacy-2',
          'expires_in': 900,
          'refresh_expires_in': 86400,
        });
      });
      SharedPreferences.setMockInitialValues({
        'auth_username': 'ada',
        'auth_access_token': 'old-access',
        'auth_refresh_token': 'legacy-1',
        'auth_expires_at': 0,
        'auth_refresh_expires_at':
            DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
      });
      final tokens = TokenManager(
        oidc: _FakeOp().service(),
        legacyAuth: AuthService(baseUrl: _issuer, httpClient: client),
        storage: await _storage(),
      );
      await tokens.load();

      await tokens.refreshTracker();

      expect(calls, ['/auth/refresh']);
      expect(tokens.isLegacy, isTrue);
      expect(tokens.accessToken, legacyAccess);
      // Its token is addressed to both apps.
      expect(tokens.calendarAccessToken, legacyAccess);
      expect((await (await _storage()).loadLegacy())?.tokens.refreshToken, 'legacy-2');
    });

    test('a legacy session without the tracker scope ends', () async {
      final client = MockClient(
        (_) async => _json({
          'access_token': _jwt({'sub': 'user-1', 'scopes': {'calendar': true}}),
          'refresh_token': 'legacy-2',
          'expires_in': 900,
          'refresh_expires_in': 86400,
        }),
      );
      SharedPreferences.setMockInitialValues({
        'auth_username': 'ada',
        'auth_access_token': 'old-access',
        'auth_refresh_token': 'legacy-1',
        'auth_expires_at': 0,
        'auth_refresh_expires_at':
            DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
      });
      final tokens = TokenManager(
        oidc: _FakeOp().service(),
        legacyAuth: AuthService(baseUrl: _issuer, httpClient: client),
        storage: await _storage(),
      );
      await tokens.load();

      await expectLater(
        tokens.refreshTracker(),
        throwsA(
          isA<AuthRejectedException>().having(
            (e) => e.message,
            'message',
            noTrackerAccessMessage,
          ),
        ),
      );
    });

    test('signing in through the OP replaces a legacy session', () async {
      SharedPreferences.setMockInitialValues({
        'auth_username': 'ada',
        'auth_access_token': 'old-access',
        'auth_refresh_token': 'legacy-1',
        'auth_expires_at': 0,
        'auth_refresh_expires_at': 0,
      });
      final tokens = await signedIn(_FakeOp());

      expect(tokens.isLegacy, isFalse);
      expect(await (await _storage()).loadLegacy(), isNull);
    });
  });

  group('AuthProvider', () {
    late _FakeOp op;
    late List<Uri> opened;
    late FutureOr<String> Function(Uri url) browser;

    AuthProvider provider() => AuthProvider(
      authService: AuthService(baseUrl: _issuer, httpClient: op.client),
      oidcService: op.service(),
      profileService: ProfileService(
        baseUrl: 'https://tracker.example',
        httpClient: MockClient(
          (_) async => _json({'id': 'user-1', 'name': 'Ada', 'avatar_url': ''}),
        ),
      ),
      callbackScheme: 'com.legacy.legacytracker',
      browser: (url, scheme) async {
        opened.add(url);
        return browser(url);
      },
    );

    Future<AuthProvider> ready() async {
      final auth = provider();
      while (auth.isInitializing) {
        await Future<void>.delayed(Duration.zero);
      }
      return auth;
    }

    /// The OP accepts the sign-in (remembering its nonce for the ID token).
    String accept(Uri url) {
      op.nonce = url.queryParameters['nonce'];
      return _callbackFor(url);
    }

    setUp(() {
      op = _FakeOp();
      opened = [];
      browser = accept;
    });

    test('signs in through the browser and loads the account', () async {
      final auth = await ready();

      await auth.signIn();

      expect(auth.isAuthenticated, isTrue);
      expect(auth.username, 'ada');
      expect(auth.profile?.id, 'user-1');
      expect(auth.errorMessage, isNull);
      expect(jwtClaims(auth.accessToken)?['aud'], 'tracker');
      expect(jwtClaims(auth.calendarAccessToken)?['aud'], 'calendar');
      expect(auth.hasCalendarScope, isTrue);
      auth.dispose();
    });

    test('asks again without the calendar when the OP denies the sign-in', () async {
      browser = (url) => url.queryParametersAll['resource']!.length == 2
          ? _callbackFor(url, error: 'access_denied')
          : accept(url);
      op.calendar = false;
      final auth = await ready();

      await auth.signIn();

      expect(opened, hasLength(2));
      expect(opened.last.queryParametersAll['resource'], [trackerResource]);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.hasCalendarScope, isFalse);
      auth.dispose();
    });

    test('explains an account without tracker access', () async {
      browser = (url) => _callbackFor(url, error: 'access_denied');
      final auth = await ready();

      await auth.signIn();

      expect(auth.isAuthenticated, isFalse);
      expect(auth.errorMessage, noTrackerAccessMessage);
      auth.dispose();
    });

    test('closing the browser is not an error', () async {
      browser = (url) => throw PlatformException(code: 'CANCELED');
      final auth = await ready();

      await auth.signIn();

      expect(auth.isAuthenticated, isFalse);
      expect(auth.errorMessage, isNull);
      auth.dispose();
    });

    test('resumes a stored grant with a refresh at launch', () async {
      final first = await ready();
      await first.signIn();
      first.dispose();
      op.tokenRequests.clear();

      final auth = await ready();

      expect(auth.isAuthenticated, isTrue);
      expect(op.tokenRequests.first['resource'], trackerResource);
      auth.dispose();
    });

    test('a refused grant at launch signs out', () async {
      final first = await ready();
      await first.signIn();
      first.dispose();
      op.current = 'revoked-elsewhere';

      final auth = await ready();

      expect(auth.isAuthenticated, isFalse);
      expect(auth.errorMessage, sessionEndedMessage);
      expect(await (await _storage()).loadGrant(), isNull);
      auth.dispose();
    });

    test('offline at launch keeps the session', () async {
      final first = await ready();
      await first.signIn();
      first.dispose();
      op.offline = true;

      final auth = await ready();

      expect(auth.isAuthenticated, isTrue);
      expect(auth.profile?.id, 'user-1');
      expect(await (await _storage()).loadGrant(), isNotNull);
      auth.dispose();
    });

    test('signs out here, then at the OP', () async {
      final auth = await ready();
      await auth.signIn();
      browser = (url) => 'com.legacy.legacytracker:/logout';

      await auth.logout();

      expect(auth.isAuthenticated, isFalse);
      expect(await (await _storage()).loadGrant(), isNull);
      expect(opened.last.path, '/logout');
      expect(opened.last.queryParameters['id_token_hint'], isNotNull);
      auth.dispose();
    });
  });
}
