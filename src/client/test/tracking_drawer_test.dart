import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/data/models/user_model.dart';
import 'package:legacytracker/src/data/network/auth_service.dart';
import 'package:legacytracker/src/data/network/oidc_service.dart';
import 'package:legacytracker/src/data/network/profile_service.dart';
import 'package:legacytracker/src/features/auth/auth_provider.dart';
import 'package:legacytracker/src/features/tracking/local_avatar_store.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_users_drawer.dart';
import 'package:provider/provider.dart';

/// The sheet has to tell the map how much of it is covered as soon as it is
/// laid out: without that first report the map keeps an inset of 0 and paints
/// its logo under the collapsed sheet until the first drag.
///
/// It also owns no selection of its own: the selected person lives in the
/// screen, so closing the detail pane has to clear it there too. Otherwise the
/// person stays ringed on the map (and highlighted in the list) after the user
/// goes back to everyone.
///
/// The people used outside the host below have no fix and share with the user,
/// so they are not listed and the detail pane (which needs the app's auth
/// providers) never builds - those tests are about the sheet opening.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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
                onSelectionCleared: () {},
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
                onSelectionCleared: () {},
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
    // The sheet animates on a timer; advance past its 240 ms.
    await tester.pump(const Duration(milliseconds: 400));

    expect(sizes.last, greaterThan(collapsed));
  });

  testWidgets('going back to all people clears the selection', (tester) async {
    final host = _DrawerHost();
    await tester.pumpWidget(host.build());
    await _expand(tester);

    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();

    expect(host.lastSelectedId, 'bob');
    expect(host.selectedUserId, 'bob');
    expect(find.text('All people'), findsOneWidget);

    await tester.tap(find.byTooltip('All people'));
    await tester.pumpAndSettle();

    expect(host.clearCalls, 1);
    expect(host.selectedUserId, isNull);
    expect(find.text('People'), findsOneWidget);
    expect(find.text('All people'), findsNothing);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('clearing the selection elsewhere returns to the list', (
    tester,
  ) async {
    final host = _DrawerHost(initialSelection: 'bob');
    await tester.pumpWidget(host.build());
    await _expand(tester);

    expect(find.text('All people'), findsOneWidget);

    // This is what the Android back gesture does through the screen.
    host.clearSelection();
    await tester.pumpAndSettle();

    expect(find.text('People'), findsOneWidget);
    expect(find.text('All people'), findsNothing);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('collapse folds the sheet back to its peek', (tester) async {
    final key = GlobalKey<TrackingUsersDrawerState>();
    final sizes = <double>[];

    Widget build(String? selected) {
      return MultiProvider(
        providers: [
          Provider<LocalAvatarStore?>.value(value: null),
          ChangeNotifierProvider<AuthProvider>.value(value: _anonymousAuth()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 800,
              child: TrackingUsersDrawer(
                key: key,
                selfProfile: UserProfile(id: 'me', name: 'Me'),
                peers: [
                  UserProfile(id: 'bob', name: 'Bob', sharesWithMe: false),
                ],
                selfTrackingPaused: false,
                selfMissingPermissions: false,
                selfBatterySavingEnabled: false,
                selectedUserId: selected,
                onUserSelected: (_) {},
                onSelectionCleared: () {},
                onExtentChanged: sizes.add,
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(build(null));
    await _expand(tester);
    await tester.pumpWidget(build('bob'));
    await tester.pumpAndSettle();
    final expanded = sizes.last;
    expect(expanded, greaterThan(0.1));

    // The Android back gesture: the detail is gone and the sheet stops
    // covering the map.
    key.currentState!.collapse();
    await tester.pumpAndSettle();
    // The sheet animates on a timer; advance past its 240 ms.
    await tester.pump(const Duration(milliseconds: 400));

    expect(sizes.last, lessThan(expanded));
  });
}

/// The list is only laid out while the sheet is open; collapsed it is just the
/// 68 px header.
Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.text('People'));
  await tester.pumpAndSettle();
}

class _DrawerHost {
  _DrawerHost({String? initialSelection}) : selectedUserId = initialSelection;

  String? selectedUserId;
  String? lastSelectedId;
  int clearCalls = 0;
  int _selectionTick = 0;
  final _notifier = _Rebuild();
  late final AuthProvider _auth = _anonymousAuth();

  Widget build() {
    return MultiProvider(
      providers: [
        Provider<LocalAvatarStore?>.value(value: null),
        ChangeNotifierProvider<AuthProvider>.value(value: _auth),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 800,
            child: ListenableBuilder(
              listenable: _notifier,
              builder: (context, _) => TrackingUsersDrawer(
                selfProfile: UserProfile(id: 'me', name: 'Me'),
                // Not sharing keeps the row tappable without a location, so
                // the detail pane never reaches for Nominatim or history.
                peers: [
                  UserProfile(id: 'bob', name: 'Bob', sharesWithMe: false),
                ],
                selfTrackingPaused: false,
                selfMissingPermissions: false,
                selfBatterySavingEnabled: false,
                selectedUserId: selectedUserId,
                selectionTick: _selectionTick,
                onUserSelected: (user) {
                  selectedUserId = user.id;
                  lastSelectedId = user.id;
                  _selectionTick++;
                  _notifier.notify();
                },
                onSelectionCleared: () {
                  clearCalls++;
                  selectedUserId = null;
                  _notifier.notify();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void clearSelection() {
    selectedUserId = null;
    _notifier.notify();
  }
}

class _Rebuild extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// Signed out, so the detail pane does not try to load anyone's history.
AuthProvider _anonymousAuth() {
  final auth = AuthProvider(
    authService: AuthService(),
    oidcService: OidcService(
      issuer: 'https://auth.example',
      clientId: 'tracker-mobile',
      redirectUri: 'com.legacy.legacytracker://callback',
      postLogoutRedirectUri: 'com.legacy.legacytracker://logout',
    ),
    profileService: ProfileService(baseUrl: 'https://tracker.example'),
    callbackScheme: 'com.legacy.legacytracker',
    browser: (_, _) async => throw UnimplementedError(),
  );
  return auth;
}
