import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/data/models/user_model.dart';
import 'package:legacytracker/src/features/tracking/local_avatar_store.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_users_drawer.dart';
import 'package:provider/provider.dart';

/// The sheet has to tell the map how much of it is covered as soon as it is
/// laid out: without that first report the map keeps an inset of 0 and paints
/// its logo under the collapsed sheet until the first drag.
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
}
