import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/data/network/auth_service.dart';
import 'package:legacytracker/src/data/network/profile_service.dart';
import 'package:legacytracker/src/features/auth/auth_provider.dart';
import 'package:legacytracker/src/features/auth/passkey_client.dart';

import 'passkey_fixtures.dart';

const _tokenResponse = {
  'access_token': 'header.payload.signature',
  'refresh_token': 'refresh',
  'expires_in': 900,
  'refresh_expires_in': 2592000,
};

// As Legacy Auth sends them: no RP ID, which a browser takes from the page.
const _requestOptions = {
  'challenge': 'Y2hhbGxlbmdl',
  'timeout': 60000,
  'userVerification': 'preferred',
  'allowCredentials': <Object>[],
};

const _creationOptions = {
  'challenge': 'Y2hhbGxlbmdl',
  'rp': {'name': 'Legacy Auth'},
  'user': {'id': 'dXNlcg', 'name': 'alice', 'displayName': 'alice'},
  'pubKeyCredParams': [
    {'type': 'public-key', 'alg': -7},
    {'type': 'public-key', 'alg': -257},
  ],
  'timeout': 60000,
  'attestation': 'none',
  'authenticatorSelection': {
    'residentKey': 'preferred',
    'requireResidentKey': false,
    'userVerification': 'preferred',
  },
};

final _assertion = AuthenticateResponseType(
  id: 'Y3JlZA',
  rawId: 'Y3JlZA',
  clientDataJSON: 'Y2xpZW50',
  authenticatorData: 'YXV0aA',
  signature: 'c2ln',
  userHandle: 'dXNlcg',
);

/// Stands in for the platform authenticator (Credential Manager / iOS).
class _FakeAuthenticator extends PasskeyAuthenticator {
  _FakeAuthenticator({this.error, this.attestationObject = p256Attestation});

  final AuthenticatorException? error;
  final String attestationObject;
  AuthenticateRequestType? authenticateRequest;
  RegisterRequestType? registerRequest;
  SignalUnknownCredentialRequestType? signalled;

  @override
  Future<AuthenticateResponseType> authenticate(
    AuthenticateRequestType request,
  ) async {
    authenticateRequest = request;
    if (error != null) throw error!;
    return _assertion;
  }

  @override
  Future<RegisterResponseType> register(RegisterRequestType request) async {
    registerRequest = request;
    if (error != null) throw error!;
    return RegisterResponseType(
      id: 'Y3JlZA',
      rawId: 'Y3JlZA',
      clientDataJSON: 'Y2xpZW50',
      attestationObject: attestationObject,
      transports: const ['internal', 'hybrid'],
    );
  }

  @override
  Future<void> signalUnknownCredential(
    SignalUnknownCredentialRequestType request,
  ) async {
    signalled = request;
  }
}

String _jwt(Map<String, Object> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'ES256'})}.${part(claims)}.c2ln';
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthService', () {
    AuthService service(MockClientHandler handler) => AuthService(
      baseUrl: 'https://auth.example',
      httpClient: MockClient(handler),
    );

    test('a wrong password reads as such', () async {
      final auth = service((_) async => _json({'error': 'Invalid credentials'}, 401));
      await expectLater(
        auth.login('alice', 'nope'),
        throwsA(
          isA<AuthException>()
              .having((e) => e.message, 'message', 'Wrong username or password.')
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('a disabled account is explained', () async {
      final auth = service((_) async => _json({'error': 'Account disabled'}, 403));
      await expectLater(
        auth.login('alice', 'secret'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            'This account has been disabled.',
          ),
        ),
      );
    });

    test('an unreachable server is a connection problem', () async {
      final auth = service((_) async => throw http.ClientException('refused'));
      await expectLater(
        auth.login('alice', 'secret'),
        throwsA(
          isA<AuthException>()
              .having((e) => e.message, 'message', contains('Can\'t reach the server'))
              .having((e) => e.statusCode, 'statusCode', isNull),
        ),
      );
    });

    test('server errors do not leak response bodies', () async {
      final auth = service((_) async => http.Response('<html>Bad gateway</html>', 502));
      await expectLater(
        auth.login('alice', 'secret'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            'Sign-in failed (error 502).',
          ),
        ),
      );
    });

    test('passkey sign-in posts the assertion and returns tokens', () async {
      late http.Request sent;
      final auth = service((request) async {
        sent = request;
        return _json(_tokenResponse);
      });
      final tokens = await auth.passkeyLogin({'id': 'Y3JlZA'});
      expect(sent.url.path, '/auth/passkey/login-verify');
      expect(jsonDecode(sent.body), {'id': 'Y3JlZA'});
      expect(tokens.refreshToken, 'refresh');
    });

    test('the options name the auth server as the relying party', () async {
      final auth = service((request) async {
        return request.url.path.endsWith('/login-options')
            ? _json(_requestOptions)
            : _json(_creationOptions);
      });
      expect((await auth.passkeyLoginOptions())['rpId'], 'auth.example');
      final creation = await auth.passkeyRegistrationOptions('jwt');
      expect(creation['rp'], {'name': 'Legacy Auth', 'id': 'auth.example'});

      // One the server names itself is kept.
      final named = service((_) async => _json({..._requestOptions, 'rpId': 'example'}));
      expect((await named.passkeyLoginOptions())['rpId'], 'example');
    });

    test('registerPasskey sends the public key and provider name', () async {
      late http.Request sent;
      final auth = service((request) async {
        sent = request;
        return _json({'success': true, 'credentialId': 'Y3JlZA', 'deviceName': 'Samsung Pass'});
      });
      final passkey = await auth.registerPasskey(
        'jwt',
        {
          'id': 'Y3JlZA',
          'response': {'clientDataJSON': 'Y2xpZW50', 'attestationObject': 'YXR0'},
        },
        publicKey: 'cGs',
        name: 'Samsung Pass',
      );
      expect(sent.url.path, '/auth/passkey/register-verify');
      expect(jsonDecode(sent.body), {
        'id': 'Y3JlZA',
        'response': {
          'clientDataJSON': 'Y2xpZW50',
          'attestationObject': 'YXR0',
          'publicKey': 'cGs',
        },
        'deviceName': 'Samsung Pass',
      });
      expect(passkey.id, 'Y3JlZA');
      expect(passkey.name, 'Samsung Pass');
    });

    test('listPasskeys parses credentials and reports an old server as null', () async {
      final auth = service((request) async {
        expect(request.url.path, '/auth/passkey/credentials');
        expect(request.headers['authorization'], 'Bearer jwt');
        return _json([
          {
            'id': 'Y3JlZA',
            'deviceName': 'Google Password Manager',
            'createdAt': '2026-10-08T10:00:00.000Z',
          },
        ]);
      });
      final passkeys = await auth.listPasskeys('jwt');
      expect(passkeys, hasLength(1));
      expect(passkeys!.single.id, 'Y3JlZA');
      expect(passkeys.single.name, 'Google Password Manager');
      expect(passkeys.single.createdAt, DateTime.utc(2026, 10, 8, 10));

      final legacy = service((_) async => _json({'error': 'Not found'}, 404));
      expect(await legacy.listPasskeys('jwt'), isNull);
    });

    test('a server without passkeys says so instead of "Not found"', () async {
      for (final status in [404, 503]) {
        final auth = service((_) async => _json({'error': 'Not found'}, status));
        await expectLater(
          auth.passkeyLoginOptions(),
          throwsA(isA<AuthException>().having((e) => e.message, 'message', contains('aren\'t available yet'))),
        );
        await expectLater(
          auth.passkeyRegistrationOptions('jwt'),
          throwsA(isA<AuthException>().having((e) => e.message, 'message', contains('aren\'t available yet'))),
        );
      }
    });

    test('deleting an already-removed passkey succeeds', () async {
      late http.Request sent;
      final auth = service((request) async {
        sent = request;
        return _json({'error': 'Not found'}, 404);
      });
      await auth.deletePasskey('jwt', 'Y3JlZA');
      expect(sent.method, 'DELETE');
      expect(sent.url.path, '/auth/passkey/credentials/Y3JlZA');
    });
  });

  group('PasskeyClient', () {
    test('signIn hands the server options to the platform and back', () async {
      final requests = <http.Request>[];
      final authenticator = _FakeAuthenticator();
      final client = PasskeyClient(
        authService: AuthService(
          baseUrl: 'https://auth.example',
          httpClient: MockClient((request) async {
            requests.add(request);
            return request.url.path.endsWith('-options')
                ? _json(_requestOptions)
                : _json(_tokenResponse);
          }),
        ),
        authenticator: authenticator,
      );

      final tokens = await client.signIn();

      expect(authenticator.authenticateRequest!.relyingPartyId, 'auth.example');
      expect(authenticator.authenticateRequest!.challenge, 'Y2hhbGxlbmdl');
      expect(authenticator.authenticateRequest!.userVerification, 'preferred');
      expect(requests.map((r) => r.url.path), [
        '/auth/passkey/login-options',
        '/auth/passkey/login-verify',
      ]);
      expect(jsonDecode(requests.last.body), _assertion.toJson());
      expect(tokens.accessToken, 'header.payload.signature');
    });

    test('a dismissed prompt is a cancellation, not an error', () async {
      final client = PasskeyClient(
        authService: AuthService(
          baseUrl: 'https://auth.example',
          httpClient: MockClient((_) async => _json(_requestOptions)),
        ),
        authenticator: _FakeAuthenticator(error: PasskeyAuthCancelledException()),
      );
      await expectLater(
        client.signIn(),
        throwsA(isA<PasskeyException>().having((e) => e.cancelled, 'cancelled', true)),
      );
    });

    test('no passkey on the phone points to the password', () async {
      final client = PasskeyClient(
        authService: AuthService(
          baseUrl: 'https://auth.example',
          httpClient: MockClient((_) async => _json(_requestOptions)),
        ),
        authenticator: _FakeAuthenticator(error: NoCredentialsAvailableException()),
      );
      await expectLater(
        client.signIn(),
        throwsA(
          isA<PasskeyException>()
              .having((e) => e.cancelled, 'cancelled', false)
              .having((e) => e.message, 'message', contains('Sign in with your password')),
        ),
      );
    });

    test('a passkey deleted server-side is forgotten by the platform', () async {
      final authenticator = _FakeAuthenticator();
      final client = PasskeyClient(
        authService: AuthService(
          baseUrl: 'https://auth.example',
          httpClient: MockClient((request) async {
            return request.url.path.endsWith('-options')
                ? _json(_requestOptions)
                : _json({'error': 'Unknown passkey credential'}, 401);
          }),
        ),
        authenticator: authenticator,
      );

      await expectLater(
        client.signIn(),
        throwsA(isA<PasskeyException>().having((e) => e.message, 'message', contains('removed'))),
      );
      expect(authenticator.signalled!.credentialId, 'Y3JlZA');
      expect(authenticator.signalled!.relyingPartyId, 'auth.example');
    });

    test('create registers with the account session', () async {
      final requests = <http.Request>[];
      final authenticator = _FakeAuthenticator();
      final client = PasskeyClient(
        authService: AuthService(
          baseUrl: 'https://auth.example',
          httpClient: MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('-options')) return _json(_creationOptions);
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return _json({
              'success': true,
              'credentialId': body['id'],
              'deviceName': body['deviceName'] ?? 'Biometric Passkey',
            });
          }),
        ),
        authenticator: authenticator,
      );

      final passkey = await client.create('jwt');

      expect(authenticator.registerRequest!.relyingParty.id, 'auth.example');
      expect(authenticator.registerRequest!.user.name, 'alice');
      expect(requests.map((r) => r.url.path), [
        '/auth/passkey/register-options',
        '/auth/passkey/register-verify',
      ]);
      expect(requests.every((r) => r.headers['authorization'] == 'Bearer jwt'), isTrue);
      final body = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(body['response']['attestationObject'], p256Attestation);
      expect(body['response']['publicKey'], p256PublicKey);
      expect(body['response']['transports'], ['internal', 'hybrid']);
      expect(body['deviceName'], 'Google Password Manager');
      expect(passkey.id, 'Y3JlZA');
      expect(passkey.name, 'Google Password Manager');
    });

    test('a key the server can\'t verify is refused before saving', () async {
      final requests = <http.Request>[];
      final client = PasskeyClient(
        authService: AuthService(
          baseUrl: 'https://auth.example',
          httpClient: MockClient((request) async {
            requests.add(request);
            return _json(_creationOptions);
          }),
        ),
        authenticator: _FakeAuthenticator(attestationObject: 'YXR0'),
      );

      await expectLater(
        client.create('jwt'),
        throwsA(isA<PasskeyException>().having((e) => e.message, 'message', contains('another provider'))),
      );
      expect(requests, hasLength(1));
    });
  });

  group('AuthProvider.loginWithPasskey', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    AuthProvider provider(_FakeAuthenticator authenticator, String accessToken) {
      final authService = AuthService(
        baseUrl: 'https://auth.example',
        httpClient: MockClient((request) async {
          return request.url.path.endsWith('-options')
              ? _json(_requestOptions)
              : _json({..._tokenResponse, 'access_token': accessToken});
        }),
      );
      return AuthProvider(
        authService: authService,
        profileService: ProfileService(
          baseUrl: 'https://tracker.example',
          httpClient: MockClient((_) async => _json({'id': 'user-1', 'name': 'Alice'})),
        ),
        passkeyClient: PasskeyClient(authService: authService, authenticator: authenticator),
      );
    }

    test('signs in as the user named in the token', () async {
      final auth = provider(
        _FakeAuthenticator(),
        _jwt({
          'sub': 'user-1',
          'username': 'alice',
          'scopes': {'calendar': false, 'tracker': true},
        }),
      );
      await auth.loginWithPasskey();

      expect(auth.isAuthenticated, isTrue);
      expect(auth.username, 'alice');
      expect(auth.profile!.id, 'user-1');
      expect(auth.errorMessage, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_username'), 'alice');
    });

    test('a dismissed prompt leaves no error behind', () async {
      final auth = provider(
        _FakeAuthenticator(error: PasskeyAuthCancelledException()),
        _jwt({'sub': 'user-1'}),
      );
      await auth.loginWithPasskey();

      expect(auth.isAuthenticated, isFalse);
      expect(auth.errorMessage, isNull);
      expect(auth.isLoading, isFalse);
    });

    test('a failed passkey sign-in surfaces its message', () async {
      final auth = provider(
        _FakeAuthenticator(error: NoCredentialsAvailableException()),
        _jwt({'sub': 'user-1'}),
      );
      await expectLater(auth.loginWithPasskey(), throwsA(isA<PasskeyException>()));

      expect(auth.isAuthenticated, isFalse);
      expect(auth.errorMessage, contains('no passkey for Legacy Tracker'));
    });
  });
}
