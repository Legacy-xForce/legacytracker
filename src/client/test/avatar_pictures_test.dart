import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:legacytracker/src/features/tracking/avatar_pictures.dart';
import 'package:legacytracker/src/features/tracking/widgets/user_avatar.dart';

/// A real 1x1 PNG: [AvatarPictures] decodes what it fetches, so a stand-in
/// string would not do.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
  'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _userId = 'acc3b458-2b51-4e73-9a48-092450b882ee';
const _authUrl = 'https://auth.legacy-group.tech/auth/profile-picture/$_userId';

http.Response _image() =>
    http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});

http.Response _html() => http.Response('<html>sign in</html>', 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('avatarCandidateUrls', () {
    test('asks Legacy Auth first and keeps the stored URL as a fallback', () {
      expect(
        avatarCandidateUrls(_userId, avatarUrl: 'https://old.example/a.png'),
        [_authUrl, 'https://old.example/a.png'],
      );
    });

    test('does not repeat the stored URL when it is the Legacy Auth one', () {
      expect(avatarCandidateUrls(_userId, avatarUrl: _authUrl), [_authUrl]);
    });

    test('ids that are not accounts have no Legacy Auth picture', () {
      expect(avatarCandidateUrls('alice'), isEmpty);
      expect(
        avatarCandidateUrls('alice', avatarUrl: 'https://old.example/a.png'),
        ['https://old.example/a.png'],
      );
    });
  });

  group('AvatarPictures', () {
    test('keeps the first picture that decodes for the session', () async {
      var requests = 0;
      final pictures = AvatarPictures(
        client: MockClient((request) async {
          requests++;
          expect(request.url.toString(), _authUrl);
          return _image();
        }),
      );

      final first = await pictures.load('key', [_authUrl]);
      expect(first.bytes, isNotNull);

      final second = await pictures.load('key', [_authUrl]);
      expect(second.bytes, same(first.bytes));
      expect(requests, 1, reason: 'a cached picture is not fetched again');
    });

    test('falls through a 200 that is not a picture', () async {
      final pictures = AvatarPictures(
        client: MockClient((request) async {
          return request.url.toString() == _authUrl ? _html() : _image();
        }),
      );

      final picture = await pictures.load('key', [
        _authUrl,
        'https://old.example/a.png',
      ]);
      expect(picture.bytes, isNotNull);
    });

    test('a hanging candidate times out and the next one is tried', () async {
      final pictures = AvatarPictures(
        client: MockClient((request) {
          if (request.url.toString() == _authUrl) {
            // Never answers: the old code had no timeout here, so the Legacy
            // Auth picture was never reached.
            return Completer<http.Response>().future;
          }
          return Future.value(_image());
        }),
        requestTimeout: const Duration(milliseconds: 20),
      );

      final picture = await pictures.load('key', [
        _authUrl,
        'https://old.example/a.png',
      ]);
      expect(picture.bytes, isNotNull);
    });

    test(
      'a 404 is a definitive "no picture", not a failure to retry',
      () async {
        var requests = 0;
        final pictures = AvatarPictures(
          client: MockClient((request) async {
            requests++;
            return http.Response('{"error":"Not found"}', 404);
          }),
          retryDelays: const [Duration.zero, Duration.zero],
        );

        final first = await pictures.load('key', [_authUrl]);
        expect(first.bytes, isNull);
        expect(first.retryable, isFalse);

        await pictures.load('key', [_authUrl]);
        expect(requests, 1, reason: 'a missing picture is remembered');
      },
    );

    test('retries a temporary failure and shows the picture', () async {
      var requests = 0;
      final pictures = AvatarPictures(
        client: MockClient((request) async {
          requests++;
          return requests == 1 ? http.Response('oops', 503) : _image();
        }),
        retryDelays: const [Duration.zero],
      );

      final picture = await pictures.load('key', [_authUrl]);
      expect(picture.bytes, isNotNull);
      expect(requests, 2);
    });

    test('reports an exhausted retry as worth trying again', () async {
      var online = false;
      final pictures = AvatarPictures(
        client: MockClient((request) async {
          return online ? _image() : http.Response('oops', 503);
        }),
        retryDelays: const [Duration.zero],
      );

      final failed = await pictures.load('key', [_authUrl]);
      expect(failed.bytes, isNull);
      expect(failed.retryable, isTrue);
      expect(
        pictures.peek('key'),
        isNull,
        reason: 'a temporary failure is not cached as final',
      );

      online = true;
      final retried = await pictures.load('key', [_authUrl]);
      expect(retried.bytes, isNotNull);
    });

    test('concurrent callers share one request', () async {
      var requests = 0;
      final response = Completer<http.Response>();
      final pictures = AvatarPictures(
        client: MockClient((request) {
          requests++;
          return response.future;
        }),
      );

      final a = pictures.load('key', [_authUrl]);
      final b = pictures.load('key', [_authUrl]);
      response.complete(_image());

      expect((await a).bytes, isNotNull);
      expect((await b).bytes, isNotNull);
      expect(requests, 1);
    });
  });

  group('UserAvatar', () {
    testWidgets('shows the initial, then the photo, without a tap', (
      tester,
    ) async {
      final response = Completer<http.Response>();
      final pictures = AvatarPictures(
        client: MockClient((request) => response.future),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UserAvatar(userId: _userId, name: 'Ada', pictures: pictures),
          ),
        ),
      );

      expect(find.text('A'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      response.complete(_image());
      // The fetch and the tiny validation decode are real async work, which
      // fake time in a widget test does not drive on its own.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      expect(find.text('A'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('remounting an avatar does not fetch the picture again', (
      tester,
    ) async {
      var requests = 0;
      final pictures = AvatarPictures(
        client: MockClient((request) async {
          requests++;
          return _image();
        }),
      );

      Widget build(Key key) => MaterialApp(
        home: Scaffold(
          body: UserAvatar(
            key: key,
            userId: _userId,
            name: 'Ada',
            pictures: pictures,
          ),
        ),
      );

      await tester.pumpWidget(build(const ValueKey('a')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(requests, 1);

      // A new key remounts the widget, as opening the details and going back
      // does. The session cache answers immediately.
      await tester.pumpWidget(build(const ValueKey('b')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(requests, 1);
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
