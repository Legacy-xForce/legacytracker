import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/features/updates/app_update_banner.dart';
import 'package:legacytracker/src/features/updates/app_updater.dart';
import 'package:legacytracker/src/features/updates/update_required_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('legacytracker/updates');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  Map<String, Object?> status({
    int? available,
    String? notes = 'Fixes signing in',
    bool failed = false,
    double? progress,
    String? lastError,
    DateTime? lastCheckAt,
    int minSupported = 0,
  }) => {
    'currentVersionCode': 11,
    'minSupportedCode': minSupported,
    'currentVersionName': '1.1.0',
    'availableVersionCode': available,
    'availableVersionName': available == null ? null : '1.2.0',
    'notes': available == null ? null : notes,
    'downloaded': false,
    'failed': failed,
    'progress': progress,
    'installPermission': true,
    'silentInstall': true,
    'automatic': true,
    'lastCheckAt': (lastCheckAt ?? DateTime.now()).millisecondsSinceEpoch,
    'lastError': lastError,
  };

  /// [current] answers `status`; [checked] (default: [current]) answers `check`.
  Future<void> pumpBanner(
    WidgetTester tester,
    Map<String, Object?> current, {
    Map<String, Object?>? checked,
  }) async {
    AppUpdater.debugSupportedOverride = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'check' => checked ?? current,
        _ => current,
      };
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppUpdateBanner())),
    );
    // Not pumpAndSettle: a download's spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  }

  tearDown(() {
    AppUpdater.debugSupportedOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  testWidgets('checks on open and stays hidden when up to date', (
    tester,
  ) async {
    await pumpBanner(tester, status());
    expect(calls, ['status', 'check']);
    expect(find.byIcon(Icons.system_update_rounded), findsNothing);
  });

  testWidgets('shows an update the check found, and installs it', (
    tester,
  ) async {
    await pumpBanner(tester, status(), checked: status(available: 12));
    expect(find.text('Version 1.2.0 is available'), findsOneWidget);
    expect(find.text('Fixes signing in'), findsOneWidget);

    await tester.tap(find.text('Install'));
    await tester.pump();
    expect(calls.last, 'install');
  });

  testWidgets('without release notes: a generic line', (tester) async {
    await pumpBanner(tester, status(available: 12, notes: ''));
    expect(find.text('Install it to get the latest fixes.'), findsOneWidget);
  });

  testWidgets('downloading: progress instead of the button', (tester) async {
    await pumpBanner(tester, status(available: 12, progress: 0.42));
    expect(find.text('Downloading… 42%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('failed download: shows the error and offers a retry', (
    tester,
  ) async {
    await pumpBanner(
      tester,
      status(available: 12, lastError: 'Download failed: HTTP 404'),
    );
    expect(find.text('Download failed: HTTP 404'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('an update that can never install has no button', (tester) async {
    await pumpBanner(tester, status(available: 12, failed: true));
    expect(find.text("Version 1.2.0 can't be installed"), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('resuming soon after a check does not ask again', (tester) async {
    await pumpBanner(tester, status());
    calls.clear();
    await resume(tester);
    expect(calls, isEmpty);
  });

  testWidgets('resuming once the last check is stale asks again', (
    tester,
  ) async {
    final stale = status(
      lastCheckAt: DateTime.now().subtract(
        AppUpdateBanner.recheckAfter + const Duration(minutes: 1),
      ),
    );
    await pumpBanner(tester, stale);
    calls.clear();
    await resume(tester);
    expect(calls, ['check']);
  });

  testWidgets('renders nothing where the app cannot update itself', (
    tester,
  ) async {
    AppUpdater.debugSupportedOverride = false;
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppUpdateBanner())),
    );
    expect(find.byIcon(Icons.system_update_rounded), findsNothing);
  });

  Future<void> pumpGate(WidgetTester tester, Map<String, Object?> current) async {
    AppUpdater.debugSupportedOverride = true;
    messenger.setMockMethodCallHandler(channel, (call) async => current);
    await tester.pumpWidget(
      const MaterialApp(home: UpdateRequiredGate(child: Text('the app'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the gate lets a supported build through', (tester) async {
    await pumpGate(tester, status(available: 12, minSupported: 11));
    expect(find.text('the app'), findsOneWidget);
    expect(find.text('Update required'), findsNothing);
  });

  testWidgets('the gate blocks a build below the minimum, offering the update', (
    tester,
  ) async {
    await pumpGate(tester, status(available: 12, minSupported: 12));
    expect(find.text('the app'), findsNothing);
    expect(find.text('Update required'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
  });
}
