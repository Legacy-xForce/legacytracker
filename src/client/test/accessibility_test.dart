import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/data/models/user_model.dart';
import 'package:legacytracker/src/features/tracking/local_avatar_store.dart';
import 'package:legacytracker/src/features/tracking/widgets/map_contents_semantics.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_users_drawer.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the people sheet header is a labelled button with a 48dp target', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MultiProvider(
        providers: [Provider<LocalAvatarStore?>.value(value: null)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 800,
              child: TrackingUsersDrawer(
                selfProfile: UserProfile(id: 'me', name: 'Me'),
                peers: const [],
                selfTrackingPaused: false,
                selfMissingPermissions: false,
                selfBatterySavingEnabled: false,
                selectedUserId: null,
                onUserSelected: (_) {},
                onSelectionCleared: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSemantics(find.bySemanticsLabel('Expand people list')),
      matchesSemantics(
        label: 'Expand people list',
        isButton: true,
        hasTapAction: true,
      ),
    );

    // Every action in the header is at least 48dp tall.
    final checkpoints = find.bySemanticsLabel('Checkpoints');
    expect(checkpoints, findsOneWidget);
    expect(
      tester.getSize(find.byType(InkWell).first).height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
    );
    expect(
      tester.getSize(find.bySemanticsLabel('Expand people list')).height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
    );
    handle.dispose();
  });

  testWidgets('the map contents list names everyone and selects on activation', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final selected = <String>[];
    final now = DateTime.now();
    final me = UserProfile(id: 'me', name: 'Me');
    final hidden = UserProfile(id: 'h', name: 'Hana', sharesWithMe: false);
    final quiet = UserProfile(
      id: 'q',
      name: 'Quinn',
      lastSeenAt: now.subtract(const Duration(days: 3)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              MapContentsSemantics(
                selfId: 'me',
                people: [me, hidden, quiet],
                onSelect: (person) => selected.add(person.id),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('People on the map'), findsOneWidget);
    expect(find.bySemanticsLabel('Me (you), no location yet'), findsOneWidget);
    expect(find.bySemanticsLabel('Hana, location hidden'), findsOneWidget);

    tester.semantics.tap(find.semantics.byLabel('Hana, location hidden'));
    expect(selected, ['h']);

    final node = tester.getSemantics(find.bySemanticsLabel('Hana, location hidden'));
    expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
    expect(node.rect.height, greaterThanOrEqualTo(kMinInteractiveDimension));
    handle.dispose();
  });

  test('labels say what is wrong with a person on the map', () {
    final me = UserProfile(id: 'me', name: 'Me');
    expect(mapContentsLabel(me, isSelf: true), 'Me (you), no location yet');
    expect(
      mapContentsLabel(
        UserProfile(id: 'x', name: 'Xi', sharesWithMe: false),
        isSelf: false,
      ),
      'Xi, location hidden',
    );
  });
}
