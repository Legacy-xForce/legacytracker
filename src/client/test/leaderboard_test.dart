import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legacytracker/src/core/periods.dart';
import 'package:legacytracker/src/data/models/leaderboard_entry.dart';
import 'package:legacytracker/src/data/network/leaderboard_service.dart';
import 'package:legacytracker/src/features/tracking/widgets/location_history_screen.dart';
import 'package:legacytracker/src/features/travel/travel_tab.dart';

void main() {
  group('periods', () {
    test('weeks run Monday to Sunday', () {
      // Sunday 18 October 2026.
      final week = Period.containing(
        PeriodKind.week,
        DateTime(2026, 10, 18, 21, 30),
      );
      expect(week.from, DateTime(2026, 10, 12));
      expect(week.to, DateTime(2026, 10, 19));
      expect(week.shift(-1).from, DateTime(2026, 10, 5));
    });

    test('months step across a year', () {
      final january = Period.containing(
        PeriodKind.month,
        DateTime(2026, 1, 31),
      );
      expect(january.from, DateTime(2026, 1, 1));
      expect(january.to, DateTime(2026, 2, 1));
      expect(january.shift(-1).from, DateTime(2025, 12, 1));
    });

    test('a custom range includes both days and steps by its length', () {
      final range = Period.custom(
        DateTime(2026, 10, 10),
        DateTime(2026, 10, 1),
      );
      expect(range.from, DateTime(2026, 10, 1));
      expect(range.to, DateTime(2026, 10, 11));
      expect(range.days, 10);
      expect(
        range.shift(-1),
        Period(PeriodKind.custom, DateTime(2026, 9, 21), DateTime(2026, 10, 1)),
      );
    });

    test('labels match the web', () {
      final now = DateTime(2026, 10, 19);
      expect(
        formatPeriod(Period.containing(PeriodKind.month, now), now: now),
        'October 2026',
      );
      expect(
        formatPeriod(Period.containing(PeriodKind.week, now), now: now),
        '19 – 25 Oct',
      );
      expect(
        formatPeriod(
          Period.containing(PeriodKind.week, DateTime(2026, 9, 30)),
          now: now,
        ),
        '28 Sep – 4 Oct',
      );
      expect(
        formatPeriod(
          Period.containing(PeriodKind.week, DateTime(2026, 1, 1)),
          now: now,
        ),
        '29 Dec 2025 – 4 Jan 2026',
      );
    });
  });

  test('entries without a user are skipped', () {
    expect(LeaderboardEntry.fromJson({'username': 'nobody'}), isNull);
    final entry = LeaderboardEntry.fromJson({'user_id': 'b', 'rank': 2})!;
    expect(entry.name, 'b');
    expect(entry.distanceMeters, 0);
  });

  group('travel tab', () {
    late List<Uri> requests;

    LeaderboardService service() => LeaderboardService(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({
            'entries': [
              {
                'user_id': 'b',
                'username': 'Bo',
                'rank': 1,
                'distance_meters': 42000,
                'duration_seconds': 3600,
                'avg_speed': 11.67,
                'top_speed': 33.4,
                'trip_count': 3,
              },
              {
                'user_id': 'me',
                'username': 'Ada',
                'rank': 2,
                'distance_meters': 0,
                'duration_seconds': 0,
                'avg_speed': 0,
                'top_speed': 0,
                'trip_count': 0,
              },
            ],
          }),
          200,
        );
      }),
    );

    Future<void> pump(WidgetTester tester, {bool active = true}) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TravelTab(
              isActive: active,
              selfId: 'me',
              baseUrl: 'https://example.test',
              getAccessToken: () => 'token',
              service: service(),
            ),
          ),
        ),
      );
      // Not shown yet, the tab only spins: there is nothing to settle.
      if (active) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
    }

    setUp(() => requests = []);

    testWidgets('ranks this week and marks you', (tester) async {
      await pump(tester);

      expect(requests, hasLength(1));
      final week = Period.containing(PeriodKind.week, DateTime.now());
      expect(
        DateTime.parse(requests.single.queryParameters['from']!).toLocal(),
        week.from,
      );
      expect(
        DateTime.parse(requests.single.queryParameters['to']!).toLocal(),
        week.to,
      );

      expect(find.text('Bo'), findsOneWidget);
      expect(find.text('42 km'), findsOneWidget);
      expect(find.text('42 km/h avg'), findsOneWidget);
      expect(find.text('120 km/h top'), findsOneWidget);
      expect(find.text('Ada (you)'), findsOneWidget);
      expect(find.text('No trips'), findsOneWidget);
      // This week is still going: nothing later to step to.
      final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right_rounded),
      );
      expect(next.onPressed, isNull);
    });

    testWidgets('tapping a person opens their trips', (tester) async {
      await pump(tester);

      await tester.tap(find.text('Bo'));
      await tester.pumpAndSettle();

      expect(find.byType(LocationHistoryScreen), findsOneWidget);
    });

    testWidgets('switches to months and steps back', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Month'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final last = requests.last.queryParameters;
      expect(
        DateTime.parse(last['from']!).toLocal(),
        DateTime(now.year, now.month - 1),
      );
      expect(
        DateTime.parse(last['to']!).toLocal(),
        DateTime(now.year, now.month),
      );
      expect(
        find.text(
          formatPeriod(
            Period.containing(
              PeriodKind.month,
              DateTime(now.year, now.month - 1),
            ),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('waits to be shown before loading', (tester) async {
      await pump(tester, active: false);
      expect(requests, isEmpty);
    });
  });
}
