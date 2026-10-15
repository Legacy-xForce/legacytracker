import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/data/models/map_viewer.dart';
import 'package:legacytracker/src/features/tracking/widgets/map_viewers_row.dart';
import 'package:legacytracker/src/features/tracking/widgets/user_avatar.dart';

void main() {
  group('MapViewer.listFromMessage', () {
    test('reads the viewers in order', () {
      final viewers = MapViewer.listFromMessage({
        'type': 'viewers',
        'viewers': [
          {'id': 'b', 'name': 'Bea'},
          {'id': 'a', 'name': 'Al'},
        ],
      })!;
      expect(viewers.map((v) => v.id), ['b', 'a']);
      expect(viewers.map((v) => v.name), ['Bea', 'Al']);
    });

    test('ignores other messages', () {
      expect(
        MapViewer.listFromMessage({'type': 'snapshot', 'users': []}),
        isNull,
      );
      expect(
        MapViewer.listFromMessage({'user_id': 'a', 'latitude': 1}),
        isNull,
      );
    });

    test('skips malformed entries and falls back to the id for a name', () {
      final viewers = MapViewer.listFromMessage({
        'type': 'viewers',
        'viewers': [
          {'id': 'a'},
          {'name': 'No id'},
          {'id': ''},
          'junk',
        ],
      })!;
      expect(viewers.map((v) => v.id), ['a']);
      expect(viewers.single.name, 'a');
    });

    test('a missing list means nobody', () {
      expect(MapViewer.listFromMessage({'type': 'viewers'}), isEmpty);
    });
  });

  group('MapViewersRow', () {
    Future<void> pumpRow(WidgetTester tester, List<MapViewer> viewers) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MapViewersRow(viewers: viewers, selfId: 'me'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    List<String> shownIds(WidgetTester tester) => tester
        .widgetList<UserAvatar>(find.byType(UserAvatar))
        .map((avatar) => avatar.userId)
        .toList();

    const me = MapViewer(id: 'me', name: 'Me');
    const al = MapViewer(id: 'al', name: 'Al');
    const bea = MapViewer(id: 'bea', name: 'Bea');
    const cy = MapViewer(id: 'cy', name: 'Cy');
    const di = MapViewer(id: 'di', name: 'Di');

    testWidgets('shows nothing while nobody is looking', (tester) async {
      await pumpRow(tester, const []);
      expect(find.byType(UserAvatar), findsNothing);
      expect(find.byType(Material), findsOneWidget); // only the Scaffold's
    });

    testWidgets('shows everyone, us first', (tester) async {
      await pumpRow(tester, const [al, me, bea]);
      expect(shownIds(tester), ['me', 'al', 'bea']);
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('counts the rest once there are too many faces', (
      tester,
    ) async {
      await pumpRow(tester, const [al, bea, me, cy, di]);
      expect(shownIds(tester), ['me', 'al']);
      expect(find.text('+3'), findsOneWidget);
    });

    testWidgets('follows the list as people come and go', (tester) async {
      await pumpRow(tester, const [me]);
      expect(shownIds(tester), ['me']);

      await pumpRow(tester, const [me, al]);
      expect(shownIds(tester), ['me', 'al']);

      await pumpRow(tester, const [al]);
      expect(shownIds(tester), ['al']);

      await pumpRow(tester, const []);
      expect(find.byType(UserAvatar), findsNothing);
    });

    testWidgets('names everyone for screen readers', (tester) async {
      await pumpRow(tester, const [me, al]);
      expect(find.bySemanticsLabel('Viewing the map: you, Al'), findsOneWidget);
    });
  });
}
