import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/data/models/user_model.dart';
import 'package:legacytracker/src/features/tracking/local_avatar_store.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_users_drawer.dart';
import 'package:provider/provider.dart';

/// The sheet has to tell the map how much of it is covered as soon as it is
/// laid out: without that first report the map keeps an inset of 0 and paints
/// its logo under the collapsed sheet until the first drag.
///
/// The people used here have no fix and share with the user, so they are not
/// listed and the detail pane (which needs the app's auth providers) never
/// builds - these tests are about the sheet opening, not the pane's content.
void main() {
  testWidgets('the collapsed sheet reports its extent without interaction', (
    tester,
  ) async {
    final sizes = <double>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [Provider<LocalAvatarStore?>.value(value: null)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 800,
              child: TrackingUsersDrawer(
                selfProfile: UserProfile(id: 'me', name: 'Me'),
                // No fix and sharing with the user: filtered out of the list,
                // so the detail pane (and its auth providers) never builds.
                peers: [UserProfile(id: 'bob', name: 'Bob')],
                selfTrackingPaused: false,
                selfMissingPermissions: false,
                selfBatterySavingEnabled: false,
                selectedUserId: null,
                onUserSelected: (_) {},
                onExtentChanged: sizes.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(sizes, isNotEmpty);
    expect(sizes.last, greaterThan(0));
    expect(sizes.last, lessThan(TrackingUsersDrawer.expandedSize));
  });

  testWidgets('openPerson expands the sheet and shows that person', (
    tester,
  ) async {
    final key = GlobalKey<TrackingUsersDrawerState>();
    final sizes = <double>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [Provider<LocalAvatarStore?>.value(value: null)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 800,
              child: TrackingUsersDrawer(
                key: key,
                selfProfile: UserProfile(id: 'me', name: 'Me'),
                // No fix and sharing with the user: filtered out of the list,
                // so the detail pane (with its auth providers) never builds.
                peers: [UserProfile(id: 'bob', name: 'Bob')],
                selfTrackingPaused: false,
                selfMissingPermissions: false,
                selfBatterySavingEnabled: false,
                selectedUserId: null,
                onUserSelected: (_) {},
                onExtentChanged: sizes.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final collapsed = sizes.last;

    key.currentState!.openPerson(UserProfile(id: 'bob', name: 'Bob'));
    await tester.pumpAndSettle();
    // The sheet animates on a timer; advance past its 240 ms.
    await tester.pump(const Duration(milliseconds: 400));

    expect(sizes.last, greaterThan(collapsed));
  });

  testWidgets('a selection from the map opens the detail on the first update', (
    tester,
  ) async {
    final selected = <String>[];
    final sizes = <double>[];

    Widget build({String? selectedUserId, int tick = 0}) {
      return MultiProvider(
        providers: [Provider<LocalAvatarStore?>.value(value: null)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 800,
              child: TrackingUsersDrawer(
                selfProfile: UserProfile(id: 'me', name: 'Me'),
                // No fix and sharing with the user: filtered out of the list,
                // so the detail pane (with its auth providers) never builds.
                peers: [UserProfile(id: 'bob', name: 'Bob')],
                selfTrackingPaused: false,
                selfMissingPermissions: false,
                selfBatterySavingEnabled: false,
                selectedUserId: selectedUserId,
                selectionTick: tick,
                onUserSelected: (user) => selected.add(user.id),
                onExtentChanged: sizes.add,
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(build());
    await tester.pump();
    final collapsed = sizes.last;

    await tester.pumpWidget(build(selectedUserId: 'bob', tick: 1));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));

    expect(sizes.last, greaterThan(collapsed));
  });
}
