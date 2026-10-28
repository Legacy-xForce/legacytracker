import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:legacytracker/src/data/models/api_token.dart';
import 'package:legacytracker/src/data/network/api_token_service.dart';
import 'package:legacytracker/src/features/auth/api_tokens_screen.dart';

const _secret = 'legacy-tracker-01a15968-64aa-707d-8904-a6a408611289';

const _yourIp = '203.0.113.7';

Map<String, dynamic> _summary({
  String id = 'tok-1',
  String name = 'Home Assistant',
  String scope = 'read',
  List<String> allowedIps = const [],
}) => {
  'id': id,
  'name': name,
  'scope': scope,
  'token_hint': 'legacy-tracker-01a1…1289',
  'allowed_ips': allowedIps,
  'created_at': '2026-10-20T08:00:00.000Z',
  'last_used_at': null,
  'rotated_at': null,
};

http.Response _reply(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

/// A fake tracker that keeps the tokens in memory, like the real one.
class _FakeTracker {
  final tokens = <Map<String, dynamic>>[];
  final requests = <http.Request>[];
  int _next = 1;

  http.Client get client => MockClient((request) async {
    requests.add(request);
    expect(request.headers['authorization'], 'Bearer jwt');
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/v1/api-tokens') {
      return _reply({'tokens': tokens, 'your_ip': _yourIp}, 200);
    }
    final update = RegExp(r'^/api/v1/api-tokens/([^/]+)$').firstMatch(path);
    if (request.method == 'PATCH' && update != null) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final ips = (body['allowed_ips'] as List<dynamic>).cast<String>();
      final bad = ips.where(
        (ip) => !RegExp(r'^[0-9a-fA-F:.]+(/\d{1,3})?$').hasMatch(ip),
      );
      if (bad.isNotEmpty) {
        return _reply({'error': '`${bad.first}` is not an IP address'}, 400);
      }
      final token = tokens.firstWhere((t) => t['id'] == update.group(1));
      token['allowed_ips'] = ips;
      return _reply(token, 200);
    }
    if (request.method == 'POST' && path == '/api/v1/api-tokens') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final created = _summary(
        id: 'tok-${_next++}',
        name: body['name'] as String,
        scope: body['scope'] as String,
      );
      tokens.insert(0, created);
      return _reply({...created, 'token': _secret}, 201);
    }
    final rotate = RegExp(
      r'^/api/v1/api-tokens/([^/]+)/rotate$',
    ).firstMatch(path);
    if (request.method == 'POST' && rotate != null) {
      final token = tokens.firstWhere((t) => t['id'] == rotate.group(1));
      return _reply({
        ...token,
        'token': '${_secret.substring(0, 40)}beefbeefbeef',
      }, 200);
    }
    if (request.method == 'DELETE') {
      tokens.removeWhere((t) => path.endsWith('/${t['id']}'));
      return _reply({'deleted': true}, 200);
    }
    return http.Response('{}', 404);
  });
}

void main() {
  group('ApiTokenService', () {
    test('creates a token and returns its one-time value', () async {
      final tracker = _FakeTracker();
      final service = ApiTokenService(
        baseUrl: 'https://tracker.example',
        httpClient: tracker.client,
      );
      final issued = await service.create(
        'jwt',
        name: 'Uploader',
        scope: ApiTokenScope.write,
      );
      expect(jsonDecode(tracker.requests.single.body), {
        'name': 'Uploader',
        'scope': 'write',
      });
      expect(issued.value, _secret);
      expect(issued.token.scope, ApiTokenScope.write);
      expect((await service.list('jwt')).tokens.single.name, 'Uploader');
    });

    test('only requests with a body send a JSON content type', () async {
      // The server rejects an empty body labelled as JSON.
      final tracker = _FakeTracker()..tokens.add(_summary());
      final service = ApiTokenService(
        baseUrl: 'https://tracker.example',
        httpClient: tracker.client,
      );
      await service.rotate('jwt', 'tok-1');
      await service.delete('jwt', 'tok-1');
      await service.create('jwt', name: 'x', scope: ApiTokenScope.read);
      await service.updateAllowedIps('jwt', 'tok-1', ['203.0.113.7']);
      final types = tracker.requests.map((r) => r.headers['content-type']);
      expect(types.take(2), [null, null]);
      expect(types.skip(2), everyElement(startsWith('application/json')));
    });

    test('shows the server message when creation is refused', () {
      final service = ApiTokenService(
        baseUrl: 'https://tracker.example',
        httpClient: MockClient(
          (_) async =>
              _reply({'error': 'You already have 25 API tokens.'}, 400),
        ),
      );
      expect(
        service.create('jwt', name: '', scope: ApiTokenScope.read),
        throwsA(
          isA<ApiTokenException>().having(
            (e) => e.message,
            'message',
            'You already have 25 API tokens.',
          ),
        ),
      );
    });

    test('saves the addresses a token may be used from', () async {
      final tracker = _FakeTracker()..tokens.add(_summary());
      final service = ApiTokenService(
        baseUrl: 'https://tracker.example',
        httpClient: tracker.client,
      );
      final updated = await service.updateAllowedIps('jwt', 'tok-1', [
        '203.0.113.7',
        '198.51.100.0/24',
      ]);
      expect(tracker.requests.single.method, 'PATCH');
      expect(tracker.requests.single.url.path, '/api/v1/api-tokens/tok-1');
      expect(jsonDecode(tracker.requests.single.body), {
        'allowed_ips': ['203.0.113.7', '198.51.100.0/24'],
      });
      expect(updated.allowedIps, ['203.0.113.7', '198.51.100.0/24']);
    });

    test('reports the address the list came from', () async {
      final tracker = _FakeTracker()..tokens.add(_summary());
      final service = ApiTokenService(
        baseUrl: 'https://tracker.example',
        httpClient: tracker.client,
      );
      expect((await service.list('jwt')).yourIp, _yourIp);
    });

    test('shows the server message when an address is refused', () {
      final service = ApiTokenService(
        baseUrl: 'https://tracker.example',
        httpClient: MockClient(
          (_) async => _reply({'error': '`nope` is not an IP address'}, 400),
        ),
      );
      expect(
        service.updateAllowedIps('jwt', 'tok-1', ['nope']),
        throwsA(
          isA<ApiTokenException>().having(
            (e) => e.message,
            'message',
            '`nope` is not an IP address',
          ),
        ),
      );
    });

    test('an entry it cannot read leaves the list empty', () {
      expect(ApiToken.fromJson(_summary(allowedIps: ['1.2.3.4'])).allowedIps, [
        '1.2.3.4',
      ]);
      expect(
        ApiToken.fromJson({..._summary(), 'allowed_ips': null}).allowedIps,
        isEmpty,
      );
      expect(
        ApiToken.fromJson({
          ..._summary(),
          'allowed_ips': ['1.2.3.4', 7],
        }).allowedIps,
        ['1.2.3.4'],
      );
    });

    test('skips entries it cannot read', () async {
      final service = ApiTokenService(
        baseUrl: 'https://tracker.example',
        httpClient: MockClient(
          (_) async => _reply({
            'tokens': [
              _summary(),
              {..._summary(id: 'bad'), 'scope': 'admin'},
            ],
          }, 200),
        ),
      );
      expect((await service.list('jwt')).tokens.map((t) => t.id), ['tok-1']);
    });
  });

  group('ApiTokensScreen', () {
    Future<_FakeTracker> pumpScreen(
      WidgetTester tester, {
      List<Map<String, dynamic>> tokens = const [],
    }) async {
      final tracker = _FakeTracker()..tokens.addAll(tokens);
      await tester.pumpWidget(
        MaterialApp(
          home: ApiTokensScreen(
            service: ApiTokenService(
              baseUrl: 'https://tracker.example',
              httpClient: tracker.client,
            ),
            accessToken: () async => 'jwt',
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tracker;
    }

    testWidgets('creates a write token and shows it once', (tester) async {
      final tracker = await pumpScreen(tester);
      expect(find.textContaining('No tokens yet'), findsOneWidget);

      await tester.tap(find.text('Create a token'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Uploader');
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create token'));
      await tester.pumpAndSettle();

      expect(tracker.tokens.single['scope'], 'write');
      expect(find.text(_secret), findsOneWidget);
      expect(find.text('Copy "Uploader" now'), findsOneWidget);
      expect(find.text('WRITE'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text(_secret), findsNothing);
    });

    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Edit Home Assistant'));
      await tester.pumpAndSettle();
    }

    /// The panel sits low in the list, so a control in it is often below the
    /// test viewport's fold.
    Future<void> tapAt(WidgetTester tester, Finder target) async {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    testWidgets('rotates only after confirming', (tester) async {
      final tracker = await pumpScreen(tester, tokens: [_summary()]);
      await openSettings(tester);
      await tester.tap(find.byTooltip('Rotate Home Assistant'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tracker.requests.where((r) => r.method == 'POST'), isEmpty);

      await tester.tap(find.byTooltip('Rotate Home Assistant'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Rotate'));
      await tester.pumpAndSettle();
      expect(tracker.requests.last.url.path, '/api/v1/api-tokens/tok-1/rotate');
      expect(find.textContaining('beefbeefbeef'), findsOneWidget);
    });

    testWidgets('deletes after confirming', (tester) async {
      final tracker = await pumpScreen(tester, tokens: [_summary()]);
      await openSettings(tester);
      await tester.tap(find.byTooltip('Delete Home Assistant'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(tracker.tokens, isEmpty);
      expect(find.text('Home Assistant'), findsNothing);
      expect(find.textContaining('No tokens yet'), findsOneWidget);
    });

    testWidgets('keeps rotate and delete inside the opened settings', (
      tester,
    ) async {
      await pumpScreen(tester, tokens: [_summary()]);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.byTooltip('Rotate Home Assistant'), findsNothing);
      expect(find.text('ALLOWED ADDRESSES'), findsNothing);

      await openSettings(tester);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('ALLOWED ADDRESSES'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.byTooltip('Rotate Home Assistant'), findsOneWidget);
      expect(find.byTooltip('Delete Home Assistant'), findsOneWidget);
    });

    testWidgets('opens a token settings by tapping its row', (tester) async {
      await pumpScreen(tester, tokens: [_summary()]);
      await tester.tap(find.text('Home Assistant'));
      await tester.pumpAndSettle();

      expect(find.text('ALLOWED ADDRESSES'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.byTooltip('Rotate Home Assistant'), findsOneWidget);
      expect(find.byTooltip('Delete Home Assistant'), findsOneWidget);

      await tester.tap(find.text('Home Assistant'));
      await tester.pumpAndSettle();
      expect(find.text('ALLOWED ADDRESSES'), findsNothing);
    });

    testWidgets('saves an address list and shows it on the token', (
      tester,
    ) async {
      final tracker = await pumpScreen(tester, tokens: [_summary()]);
      await openSettings(tester);

      // Offered before it is typed: this is what keeps a mistake from being a
      // lockout.
      expect(
        find.textContaining('Add my current address ($_yourIp)'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField).last, ' 198.51.100.0/24 ');
      await tapAt(tester, find.byTooltip('Add address'));
      expect(find.text('198.51.100.0/24'), findsOneWidget);

      await tapAt(tester, find.widgetWithText(FilledButton, 'Save'));

      expect(tracker.tokens.single['allowed_ips'], ['198.51.100.0/24']);
      expect(find.text('ALLOWED ADDRESSES'), findsNothing);
      expect(find.textContaining('From 198.51.100.0/24'), findsOneWidget);
    });

    testWidgets('lists the addresses a token already has', (tester) async {
      await pumpScreen(
        tester,
        tokens: [
          _summary(allowedIps: ['203.0.113.7', '2001:db8::/64']),
        ],
      );
      expect(
        find.textContaining('From 203.0.113.7, 2001:db8::/64'),
        findsOneWidget,
      );

      await openSettings(tester);
      expect(find.text('203.0.113.7'), findsOneWidget);
      expect(find.text('2001:db8::/64'), findsOneWidget);
      // The address being offered is already listed, so there is nothing to
      // add: the shortcut disappears rather than duplicating an entry.
      expect(find.textContaining('Add my current address'), findsNothing);
    });

    testWidgets('keeps the draft when the server refuses an entry', (
      tester,
    ) async {
      final tracker = await pumpScreen(tester, tokens: [_summary()]);
      await openSettings(tester);
      await tester.enterText(find.byType(TextField).last, 'not-an-ip');
      await tapAt(tester, find.byTooltip('Add address'));
      await tapAt(tester, find.widgetWithText(FilledButton, 'Save'));

      expect(find.textContaining('is not an IP address'), findsOneWidget);
      expect(find.text('ALLOWED ADDRESSES'), findsOneWidget);
      expect(find.text('not-an-ip'), findsOneWidget);
      expect(tracker.tokens.single['allowed_ips'], isEmpty);
    });
  });
}
