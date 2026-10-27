import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legacytracker/src/data/models/user_model.dart';
import 'package:legacytracker/src/data/network/history_service.dart';
import 'package:legacytracker/src/features/tracking/widgets/location_history_screen.dart';

/// Opens this month's history with one trip per (day, km) pair. Wide and tall
/// enough that the calendar and the month overview are both on screen.
Future<void> openHistory(
  WidgetTester tester,
  List<(int, double)> trips,
) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final now = DateTime.now();
  final sessions = [
    for (final (day, km) in trips)
      {
        'start_at': DateTime(now.year, now.month, day, 8)
            .toUtc()
            .toIso8601String(),
        'end_at': DateTime(now.year, now.month, day, 9).toUtc().toIso8601String(),
        'duration_seconds': 3600,
        'distance_meters': km * 1000,
        'avg_speed': 40,
        'top_speed': 60,
        'point_count': 0,
      },
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: LocationHistoryScreen(
        user: UserProfile(id: 'me', name: 'Me'),
        baseUrl: 'https://example.test',
        accessToken: 'token',
        historyService: HistoryService(
          baseUrl: 'https://example.test',
          httpClient: MockClient(
            (_) async => http.Response(jsonEncode({'sessions': sessions}), 200),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a day is labelled with its total km', (tester) async {
    await openHistory(tester, [(3, 6.2), (3, 6.2)]);
    expect(find.text('12km'), findsOneWidget);
  });

  testWidgets('a long travel day widens its cell rather than clipping', (
    tester,
  ) async {
    await openHistory(tester, [(3, 6.2), (3, 6.2), (5, 120)]);
    final shortDay = find.ancestor(
      of: find.text('12km'),
      matching: find.byType(InkWell),
    );
    final longDay = find.ancestor(
      of: find.text('120km'),
      matching: find.byType(InkWell),
    );
    expect(
      tester.getRect(longDay).width,
      greaterThan(tester.getRect(shortDay).width),
    );
    expect(tester.takeException(), isNull);
  });
}
