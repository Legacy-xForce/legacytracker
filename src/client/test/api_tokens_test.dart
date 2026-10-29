import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:legacytracker/src/core/theme.dart';
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

Map<String, dynamic> _request({
  required String id,
  String method = 'GET',
  String path = '/api/v1/history',
  int status = 200,
  String ip = _yourIp,
  String? userAgent = 'Home Assistant/2026.10',
  int durationMs = 12,
  String createdAt = '2026-10-20T08:15:00.000Z',
}) => {
  'id': id,
  'method': method,
  'path': path,
  'status_code': status,
  'client_ip': ip,
  'user_agent': userAgent,
  'duration_ms': durationMs,
  'created_at': createdAt,
};

http.Response _reply(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

/// A fake tracker that keeps the tokens in memory, like the real one.
class _FakeTracker {
  final tokens = <Map<String, dynamic>>[];
  final everyone = <Map<String, dynamic>>[];
  final requests = <http.Request>[];
  final requestLog = <String, List<Map<String, dynamic>>>{};
  int _next = 1;

  http.Client get client => MockClient((request) async {
    requests.add(request);
    expect(request.headers['authorization'], 'Bearer jwt');
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/v1/api-tokens/all') {
      return _reply({'tokens': everyone}, 200);
    }
    if (request.method == 'GET' && path == '/api/v1/api-tokens') {
      return _reply({'tokens': tokens, 'your_ip': _yourIp}, 200);
    }
    final log = RegExp(
      r'^/api/v1/api-tokens/([^/]+)/requests$',
    ).firstMatch(path);
    if (request.method == 'GET' && log != null) {
      final all = requestLog[log.group(1)] ?? const <Map<String, dynamic>>[];
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 50;
      final before = int.tryParse(request.url.queryParameters['before'] ?? '');
      final filtered = all
          .where((r) => before == null || int.parse(r['id'] as String) < before)
          .toList();
      final page = filtered.take(limit).toList();
      return _reply({
        'requests': page,
        'has_more': filtered.length > limit,
        'next_before': filtered.length > limit ? page.last['id'] : null,
      }, 200);
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

    test("lists every token on the tracker with its owner", () async {
      final tracker = _FakeTracker()
        ..everyone.addAll([
          {
            ..._summary(id: 'tok-2', name: 'Bob phone', scope: 'write'),
            'user_id': 'user-2',
            'user_name': 'Bob',
            'deleted': false,
          },
          {
            ..._summary(id: 'tok-3', name: 'Old key'),
            'user_id': 'user-2',
            'user_name': 'Bob',
            'deleted': true,
          },
        ]);
      final service = ApiTokenService(
        baseUrl: 'https://tracker.example',
        httpClient: tracker.client,
      );

      final tokens = await service.listAll('jwt');
      expect(tracker.requests.single.url.path, '/api/v1/api-tokens/all');
      expect(tokens.map((t) => t.id), ['tok-2', 'tok-3']);
      expect(tokens.map((t) => t.userName), ['Bob', 'Bob']);
      expect(tokens.map((t) => t.deleted), [false, true]);
      expect(tokens.first.scope, ApiTokenScope.write);
    });

    test('reads a page of request history with its cursor', () async {
      final tracker = _FakeTracker()..tokens.add(_summary());
      tracker.requestLog['tok-1'] = [
        _request(id: '3', status: 403),
        _request(id: '2', method: 'POST', path: '/api/v1/location'),
        _request(id: '1'),
      ];
      final service = ApiTokenService(
        baseUrl: 'https://tracker.example',
        httpClient: tracker.client,
      );

      final first = await service.requests('jwt', 'tok-1', limit: 2);
      expect(first.requests.map((r) => r.id), ['3', '2']);
      expect(first.requests.first.statusCode, 403);
      expect(first.hasMore, true);
      expect(first.nextBefore, '2');
      expect(tracker.requests.single.url.queryParameters, {'limit': '2'});

      final second = await service.requests(
        'jwt',
        'tok-1',
        before: first.nextBefore,
        limit: 2,
      );
      expect(second.requests.map((r) => r.id), ['1']);
      expect(second.hasMore, false);
      expect(second.nextBefore, isNull);
      expect(tracker.requests.last.url.queryParameters, {
        'limit': '2',
        'before': '2',
      });
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
          // The real theme makes FilledButtons full-width, which is what a
          // Row cannot give them: plain MaterialApp hid that regression.
          theme: buildThemeFor(AppThemeId.teal),
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

    testWidgets('opens a token request history on a page of its own', (
      tester,
    ) async {
      final tracker = await pumpScreen(tester, tokens: [_summary()]);
      tracker.requestLog['tok-1'] = [
        _request(
          id: '2',
          method: 'POST',
          path: '/api/v1/location',
          status: 403,
        ),
        _request(id: '1'),
      ];

      await tester.tap(find.byTooltip('Request history for Home Assistant'));
      await tester.pumpAndSettle();

      expect(find.text('Request history'), findsOneWidget);
      expect(find.text('/api/v1/location'), findsOneWidget);
      expect(find.text('403'), findsOneWidget);
      expect(find.text('/api/v1/history'), findsOneWidget);
      expect(find.textContaining('Home Assistant/2026.10'), findsWidgets);
      expect(find.textContaining('$_yourIp · 12 ms'), findsWidgets);
      // It is a page, not a sheet: the token list is no longer underneath.
      expect(find.text('Create a token'), findsNothing);
    });

    testWidgets('shows an empty request history', (tester) async {
      await pumpScreen(tester, tokens: [_summary()]);

      await tester.tap(find.byTooltip('Request history for Home Assistant'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No requests yet'), findsOneWidget);
    });

    testWidgets("opens everyone's tokens and a token's history", (
      tester,
    ) async {
      final tracker = await pumpScreen(tester, tokens: [_summary()]);
      tracker.everyone.addAll([
        {
          ..._summary(id: 'tok-2', name: 'Bob phone', scope: 'write'),
          'user_id': 'user-2',
          'user_name': 'Bob',
          'deleted': false,
        },
        {
          ..._summary(id: 'tok-3', name: 'Old key'),
          'user_id': 'user-2',
          'user_name': 'Bob',
          'deleted': true,
        },
      ]);
      tracker.requestLog['tok-2'] = [_request(id: '1')];

      await tester.tap(find.byTooltip("Everyone's tokens"));
      await tester.pumpAndSettle();

      expect(find.text("Everyone's tokens"), findsOneWidget);
      expect(find.text('BOB'), findsOneWidget);
      expect(find.text('Bob phone'), findsOneWidget);
      expect(find.text('WRITE'), findsOneWidget);
      expect(find.text('DELETED'), findsOneWidget);

      await tester.tap(find.byTooltip('Request history for Bob phone'));
      await tester.pumpAndSettle();

      expect(find.text('Request history'), findsOneWidget);
      expect(find.text('Owner: Bob'), findsOneWidget);
      expect(find.text('/api/v1/history'), findsOneWidget);
      expect(
        tracker.requests.last.url.path,
        '/api/v1/api-tokens/tok-2/requests',
      );
    });

    testWidgets('shows an empty everyone list', (tester) async {
      await pumpScreen(tester, tokens: [_summary()]);

      await tester.tap(find.byTooltip("Everyone's tokens"));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No tokens on the tracker yet'),
        findsOneWidget,
      );
    });
  });
}
