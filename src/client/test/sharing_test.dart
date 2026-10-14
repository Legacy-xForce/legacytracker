import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legacytracker/src/data/models/user_model.dart';
import 'package:legacytracker/src/data/network/sharing_service.dart';
import 'package:legacytracker/src/features/tracking/sharing_provider.dart';

SharingProvider providerFor(
  Future<http.Response> Function(http.Request) handler,
) {
  final provider = SharingProvider(
    service: SharingService(
      baseUrl: 'https://example.test',
      httpClient: MockClient(handler),
    ),
  );
  provider.bindSession(userId: 'me', getAccessToken: () => 'token');
  return provider;
}

http.Response hidden(List<String> ids) =>
    http.Response(jsonEncode({'hidden_from': ids}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sharing is on for everyone until the server says otherwise', () async {
    final provider = providerFor((_) async => hidden([]));
    await provider.refresh();
    expect(provider.isSharingWith('bob'), isTrue);
  });

  test('loads who we are hidden from on sign-in', () async {
    final provider = providerFor((_) async => hidden(['bob']));
    await provider.refresh();
    expect(provider.isSharingWith('bob'), isFalse);
    expect(provider.isSharingWith('carol'), isTrue);
  });

  test('switching sharing off is applied before the server answers', () async {
    final provider = providerFor((request) async {
      if (request.method == 'PUT') {
        expect(request.url.path, '/api/v1/sharing/bob');
        expect(jsonDecode(request.body), {'enabled': false});
        return hidden(['bob']);
      }
      return hidden([]);
    });
    await provider.refresh();

    final pending = provider.setSharing('bob', false);
    expect(provider.isSharingWith('bob'), isFalse);
    await pending;
    expect(provider.isSharingWith('bob'), isFalse);
  });

  test('a refused change is undone and reported', () async {
    final provider = providerFor((request) async {
      if (request.method == 'PUT') return http.Response('{}', 500);
      return hidden([]);
    });
    await provider.refresh();

    await expectLater(
      provider.setSharing('bob', false),
      throwsA(isA<SharingException>()),
    );
    expect(provider.isSharingWith('bob'), isTrue);
  });

  test('signing out forgets the settings', () async {
    final provider = providerFor((_) async => hidden(['bob']));
    await provider.refresh();
    provider.bindSession(userId: null, getAccessToken: () => null);
    expect(provider.isSharingWith('bob'), isTrue);
  });

  test('peers are assumed to share with us by default', () {
    expect(UserProfile(id: 'bob', name: 'Bob').sharesWithMe, isTrue);
  });
}
