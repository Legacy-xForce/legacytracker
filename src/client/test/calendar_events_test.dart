import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legacytracker/src/core/formatters.dart';
import 'package:legacytracker/src/data/models/calendar_event.dart';
import 'package:legacytracker/src/data/network/calendar_service.dart';
import 'package:legacytracker/src/data/network/event_geocoder.dart';
import 'package:legacytracker/src/data/network/place_search_service.dart';
import 'package:legacytracker/src/features/calendar/calendar_events_provider.dart';
import 'package:legacytracker/src/features/calendar/event_marker.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> eventJson({
  int id = 1,
  String title = 'Party',
  String? location = 'Piazza Duomo, Milano',
  DateTime? start,
  DateTime? end,
  String? color = '#ff0000',
  List<Map<String, dynamic>> participants = const [],
}) => {
  'id': id,
  'title': title,
  'color': color,
  'location': location,
  'startTime': (start ?? DateTime.now().add(const Duration(hours: 2)))
      .toUtc()
      .toIso8601String(),
  if (end != null) 'endTime': end.toUtc().toIso8601String(),
  'host': {'id': 9, 'username': 'host', 'profilePictureUrl': null},
  'participants': participants,
};

Map<String, dynamic> participant(int id, String status) => {
  'id': id,
  'username': 'user$id',
  'profilePictureUrl': null,
  'status': status,
};

PlaceSearchService nominatim(
  int Function() calls, {
  bool found = true,
  void Function()? onCall,
}) => PlaceSearchService(
  httpClient: MockClient((request) async {
    onCall?.call();
    return http.Response(
      jsonEncode(
        found
            ? [
                {'display_name': 'Somewhere', 'lat': '45.4642', 'lon': '9.19'},
              ]
            : [],
      ),
      200,
    );
  }),
);

void main() {
  group('CalendarEvent', () {
    test('is shown until its end time', () {
      final end = DateTime(2030, 1, 1, 22);
      final event = CalendarEvent.tryParse(
        eventJson(start: DateTime(2030, 1, 1, 18), end: end),
      )!;
      expect(event.isOver(end.subtract(const Duration(minutes: 1))), isFalse);
      expect(event.isOver(end), isTrue);
    });

    test('without an end it is shown until midnight of the start day', () {
      final event = CalendarEvent.tryParse(
        eventJson(start: DateTime(2030, 1, 1, 18)),
      )!;
      expect(event.isOver(DateTime(2030, 1, 1, 23, 59)), isFalse);
      expect(event.isOver(DateTime(2030, 1, 2)), isTrue);
    });

    test('attendees are the host plus accepted participants only', () {
      final event = CalendarEvent.tryParse(
        eventJson(
          participants: [
            participant(1, 'ACCEPTED'),
            participant(2, 'PENDING'),
            participant(3, 'DECLINED'),
            participant(9, 'ACCEPTED'), // the host again: counted once
          ],
        ),
      )!;
      expect(event.attendees.map((a) => a.id), ['9', '1']);
    });

    test('colors parse, and bad ones fall back to null', () {
      expect(parseHexColor('#ff0000'), const Color(0xFFFF0000));
      expect(parseHexColor('0f0'), const Color(0xFF00FF00));
      expect(parseHexColor('red'), isNull);
      expect(parseHexColor(null), isNull);
    });

    test('an event without a title or start is dropped', () {
      expect(CalendarEvent.tryParse({'id': 1, 'title': 'x'}), isNull);
      expect(CalendarEvent.tryParse({'id': 1, 'startTime': '2030-01-01'}), isNull);
    });
  });

  group('CalendarService', () {
    CalendarService serviceFor(int status, [String body = '[]']) =>
        CalendarService(
          baseUrl: 'https://example.test',
          httpClient: MockClient((_) async => http.Response(body, status)),
        );
    final from = DateTime(2030, 1, 1);

    test('sends the bearer token and the range', () async {
      late http.Request seen;
      final service = CalendarService(
        baseUrl: 'https://example.test',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('[]', 200);
        }),
      );
      await service.list('tok', from: from, to: from.add(const Duration(days: 1)));
      expect(seen.url.path, '/events');
      expect(seen.url.queryParameters.keys, containsAll(['start', 'end']));
      expect(seen.headers['authorization'], 'Bearer tok');
    });

    test('skips malformed events', () async {
      final service = serviceFor(
        200,
        jsonEncode([eventJson(), {'nonsense': true}, 5]),
      );
      expect(await service.list('t', from: from, to: from), hasLength(1));
    });

    test('403 means no access', () async {
      await expectLater(
        serviceFor(403).list('t', from: from, to: from),
        throwsA(isA<CalendarException>().having((e) => e.noAccess, 'noAccess', true)),
      );
    });

    test('a server error is not "no access"', () async {
      await expectLater(
        serviceFor(500).list('t', from: from, to: from),
        throwsA(isA<CalendarException>().having((e) => e.noAccess, 'noAccess', false)),
      );
    });
  });

  group('EventGeocoder', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('asks Nominatim once per text and remembers it across launches', () async {
      var calls = 0;
      final search = nominatim(() => calls, onCall: () => calls++);
      var geocoder = EventGeocoder(
        search: search,
        prefs: SharedPreferences.getInstance(),
        spacing: Duration.zero,
      );
      expect(await geocoder.resolve('Piazza Duomo'), isNotNull);
      expect(await geocoder.resolve('  piazza   duomo '), isNotNull);
      expect(calls, 1);

      geocoder = EventGeocoder(
        search: search,
        prefs: SharedPreferences.getInstance(),
        spacing: Duration.zero,
      );
      await geocoder.ready;
      expect(geocoder.peek('Piazza Duomo').known, isTrue);
      expect(calls, 1);
    });

    test('"not found" is remembered too', () async {
      var calls = 0;
      final geocoder = EventGeocoder(
        search: nominatim(() => calls, found: false, onCall: () => calls++),
        prefs: SharedPreferences.getInstance(),
        spacing: Duration.zero,
      );
      expect(await geocoder.resolve('Meeting Room A'), isNull);
      expect(await geocoder.resolve('Meeting Room A'), isNull);
      expect(calls, 1);
      expect(geocoder.peek('Meeting Room A').known, isTrue);
    });

    test('a failed lookup is not remembered', () async {
      var fail = true;
      final geocoder = EventGeocoder(
        search: PlaceSearchService(
          httpClient: MockClient((_) async => fail
              ? http.Response('', 500)
              : http.Response(
                  jsonEncode([
                    {'display_name': 'x', 'lat': '1', 'lon': '2'},
                  ]),
                  200,
                )),
        ),
        prefs: SharedPreferences.getInstance(),
        spacing: Duration.zero,
      );
      expect(await geocoder.resolve('Somewhere'), isNull);
      expect(geocoder.peek('Somewhere').known, isFalse);
      fail = false;
      expect(await geocoder.resolve('Somewhere'), isNotNull);
    });
  });

  group('CalendarEventsProvider', () {
    late List<Map<String, dynamic>> served;
    late int fetches;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      served = [];
      fetches = 0;
    });

    CalendarEventsProvider build({bool locationFound = true}) =>
        CalendarEventsProvider(
          service: CalendarService(
            baseUrl: 'https://example.test',
            httpClient: MockClient((_) async {
              fetches++;
              return http.Response(jsonEncode(served), 200);
            }),
          ),
          geocoder: EventGeocoder(
            search: nominatim(() => 0, found: locationFound),
            prefs: SharedPreferences.getInstance(),
            spacing: Duration.zero,
          ),
          prefs: SharedPreferences.getInstance(),
          refreshInterval: null,
        );

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

    void bind(CalendarEventsProvider p, {bool scope = true}) => p.bindSession(
      userId: 'u1',
      hasCalendarScope: scope,
      getAccessToken: () => 'tok',
    );

    test('does nothing without the calendar scope', () async {
      served = [eventJson()];
      final p = build();
      bind(p, scope: false);
      await settle();
      expect(p.available, isFalse);
      expect(fetches, 0);
      expect(p.visibleEvents, isEmpty);
    });

    test('shows placed, not-yet-over events by default', () async {
      served = [
        eventJson(id: 1),
        eventJson(
          id: 2,
          start: DateTime.now().subtract(const Duration(hours: 3)),
          end: DateTime.now().subtract(const Duration(hours: 1)),
        ),
        eventJson(id: 3, location: null),
      ];
      final p = build();
      bind(p);
      await settle();
      expect(p.enabled, isTrue);
      expect(p.visibleEvents.map((e) => e.id), ['1']);
    });

    test('a running event stays until its end', () async {
      served = [
        eventJson(
          start: DateTime.now().subtract(const Duration(hours: 1)),
          end: DateTime.now().add(const Duration(hours: 1)),
        ),
      ];
      final p = build();
      bind(p);
      await settle();
      expect(p.visibleEvents, hasLength(1));
    });

    test('events whose place cannot be found are not shown', () async {
      served = [eventJson(location: 'Meeting Room A')];
      final p = build(locationFound: false);
      bind(p);
      await settle();
      expect(p.visibleEvents, isEmpty);
    });

    test('toggling hides the overlay and is remembered', () async {
      served = [eventJson()];
      final p = build();
      bind(p);
      await settle();
      await p.toggle();
      expect(p.visibleEvents, isEmpty);
      expect((await SharedPreferences.getInstance()).getBool('calendar_events_enabled'), isFalse);

      final again = build();
      bind(again);
      await settle();
      expect(again.enabled, isFalse);
    });

    test('signing out clears the events', () async {
      served = [eventJson()];
      final p = build();
      bind(p);
      await settle();
      p.bindSession(userId: null, hasCalendarScope: false, getAccessToken: () => null);
      expect(p.visibleEvents, isEmpty);
      expect(p.available, isFalse);
    });
  });

  group('EventDetailsSheet', () {
    Future<void> show(WidgetTester tester, CalendarEvent event) =>
        tester.pumpWidget(
          MaterialApp(home: Scaffold(body: EventDetailsSheet(event: event))),
        );

    testWidgets('shows name, time until and who is coming', (tester) async {
      final event = CalendarEvent.tryParse(
        eventJson(
          title: 'Barbecue',
          start: DateTime.now().add(const Duration(hours: 3, minutes: 30)),
          participants: [participant(1, 'ACCEPTED')],
        ),
      )!;
      await show(tester, event);
      expect(find.text('Barbecue'), findsOneWidget);
      expect(find.textContaining('Starts in 3h'), findsOneWidget);
      expect(find.text('2 going'), findsOneWidget);
      expect(find.text('user1'), findsOneWidget);
      expect(find.text('Open in Legacy Calendar'), findsOneWidget);
      // Both actions are filled buttons; the calendar one is the secondary (tonal) variant.
      expect(find.widgetWithText(FilledButton, 'Go'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Open in Legacy Calendar'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a running event says so', (tester) async {
      final event = CalendarEvent.tryParse(
        eventJson(
          start: DateTime.now().subtract(const Duration(hours: 1)),
          end: DateTime.now().add(const Duration(hours: 2, minutes: 5)),
        ),
      )!;
      await show(tester, event);
      expect(find.textContaining('Happening now'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('webUri points at the event in Legacy Calendar', () {
    final event = CalendarEvent.tryParse(eventJson())!;
    expect(
      event.webUri('https://legacy-calendar.pages.dev').toString(),
      'https://legacy-calendar.pages.dev/event/${event.id}',
    );
    expect(
      event.webUri('http://10.0.2.2:5173/').toString(),
      'http://10.0.2.2:5173/event/${event.id}',
    );
  });

  test('formatUntil truncates to whole minutes', () {
    expect(formatUntil(const Duration(seconds: 30)), '<1m');
    expect(formatUntil(const Duration(hours: 3, minutes: 20, seconds: 59)), '3h 20m');
    expect(formatUntil(const Duration(minutes: 5, seconds: 59)), '5m');
  });
}
