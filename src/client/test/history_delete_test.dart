import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legacytracker/src/data/models/user_model.dart';
import 'package:legacytracker/src/data/network/history_service.dart';
import 'package:legacytracker/src/features/tracking/widgets/location_history_screen.dart';

/// A server holding today's trips that answers history reads and deletions.
class FakeHistory {
  FakeHistory() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    trips = [
      (today.add(const Duration(hours: 8)), const Duration(minutes: 20)),
      (today.add(const Duration(hours: 18)), const Duration(minutes: 10)),
    ];
  }

  late List<(DateTime, Duration)> trips;
  final deletions = <Uri>[];

  http.Client get client => MockClient((request) async {
    if (request.method == 'DELETE') {
      deletions.add(request.url);
      final from = DateTime.parse(request.url.queryParameters['from']!);
      final to = DateTime.parse(request.url.queryParameters['to']!);
      final before = trips.length;
      trips = [
        for (final trip in trips)
          if (trip.$1.isBefore(from) || trip.$1.isAfter(to)) trip,
      ];
      return http.Response(jsonEncode({'deleted': before - trips.length}), 200);
    }
    return http.Response(
      jsonEncode({
        'sessions': [
          for (final (start, length) in trips)
            {
              'start_at': start.toUtc().toIso8601String(),
              'end_at': start.add(length).toUtc().toIso8601String(),
              'duration_seconds': length.inSeconds,
              'distance_meters': 5000,
              'avg_speed': 5,
              'top_speed': 10,
              'point_count': 2,
            },
        ],
      }),
      200,
    );
  });
}

Future<void> openToday(
  WidgetTester tester,
  FakeHistory server, {
  required bool own,
}) async {
  // Tall enough that the calendar and both trips are on screen at once.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: LocationHistoryScreen(
        user: UserProfile(id: 'me', name: 'Me'),
        baseUrl: 'https://example.test',
        accessToken: 'token',
        canDelete: own,
        historyService: HistoryService(
          baseUrl: 'https://example.test',
          httpClient: server.client,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('${DateTime.now().day}'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('deleting one trip sends its start..end and reloads', (
    tester,
  ) async {
    final server = FakeHistory();
    final first = server.trips.first;
    await openToday(tester, server, own: true);
    expect(find.byTooltip('Delete this trip'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Delete this trip').first);
    await tester.pumpAndSettle();
    expect(find.text('Delete this trip?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    final query = server.deletions.single.queryParameters;
    expect(DateTime.parse(query['from']!).isAtSameMomentAs(first.$1), isTrue);
    expect(
      DateTime.parse(query['to']!).isAtSameMomentAs(first.$1.add(first.$2)),
      isTrue,
    );
    expect(server.deletions.single.path, '/api/v1/history');
    expect(find.byTooltip('Delete this trip'), findsOneWidget);
    expect(find.text('Trip deleted'), findsOneWidget);
  });

  testWidgets('cancelling the confirmation deletes nothing', (tester) async {
    final server = FakeHistory();
    await openToday(tester, server, own: true);

    await tester.tap(find.byTooltip('Delete this trip').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(server.deletions, isEmpty);
    expect(find.byTooltip('Delete this trip'), findsNWidgets(2));
  });

  testWidgets('deleting the day covers its whole local span', (tester) async {
    final server = FakeHistory();
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    await openToday(tester, server, own: true);

    await tester.tap(find.byTooltip('Delete this day\'s trips'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this day?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    final query = server.deletions.single.queryParameters;
    expect(DateTime.parse(query['from']!).isAtSameMomentAs(midnight), isTrue);
    final lastMillisecond = DateTime(
      now.year,
      now.month,
      now.day + 1,
    ).subtract(const Duration(milliseconds: 1));
    expect(
      DateTime.parse(query['to']!).isAtSameMomentAs(lastMillisecond),
      isTrue,
    );
    expect(server.trips, isEmpty);
    // Back to the month, which no longer has a trip day to pick.
    expect(find.text('No trips this month.'), findsOneWidget);
  });

  testWidgets('someone else\'s history offers no way to delete', (
    tester,
  ) async {
    final server = FakeHistory();
    await openToday(tester, server, own: false);

    expect(find.byTooltip('Delete this trip'), findsNothing);
    expect(find.byTooltip('Delete this day\'s trips'), findsNothing);
  });

  test('a failed deletion is reported, not swallowed', () async {
    final service = HistoryService(
      baseUrl: 'https://example.test',
      httpClient: MockClient((_) async => http.Response('nope', 500)),
    );
    expect(
      service.deleteHistory(
        'token',
        from: DateTime(2026, 10, 15),
        to: DateTime(2026, 10, 16),
      ),
      throwsException,
    );
  });
}
