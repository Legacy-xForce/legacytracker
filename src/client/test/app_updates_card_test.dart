import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/features/updates/app_updater.dart';
import 'package:legacytracker/src/features/updates/app_updates_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('legacytracker/updates');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  Map<String, Object?> status({
    int? available,
    bool downloaded = false,
    bool installPermission = true,
    bool silentInstall = true,
    double? progress,
    String? lastError,
  }) => {
    'currentVersionCode': 11,
    'currentVersionName': '1.1.0',
    'availableVersionCode': available,
    'availableVersionName': available == null ? null : '1.2.0',
    'notes': available == null ? null : 'Faster trip detection',
    'downloaded': downloaded,
    'progress': progress,
    'installPermission': installPermission,
    'silentInstall': silentInstall,
    'automatic': true,
    'lastCheckAt': DateTime.now().millisecondsSinceEpoch,
    'lastError': lastError,
  };

  Future<void> pumpCard(
    WidgetTester tester,
    Map<String, Object?> current, {
    Map<String, Object?>? afterInstall,
  }) async {
    AppUpdater.debugSupportedOverride = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'install' => afterInstall ?? current,
        _ => current,
      };
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppUpdatesCard())),
    );
    await tester.pump();
  }

  tearDown(() {
    AppUpdater.debugSupportedOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  testWidgets('up to date: shows the version and a check button', (
    tester,
  ) async {
    await pumpCard(tester, status());
    expect(find.text('Version 1.1.0 (11)'), findsOneWidget);
    expect(find.textContaining('Up to date'), findsOneWidget);
    expect(find.text('Check'), findsOneWidget);
    // Silent updates are set up: no permission hint.
    expect(find.text('Allow'), findsNothing);
  });

  testWidgets('downloaded update: offers install and shows the notes', (
    tester,
  ) async {
    await pumpCard(tester, status(available: 12, downloaded: true));
    expect(
      find.text('Version 1.2.0 installs by itself once you leave the app'),
      findsOneWidget,
    );
    expect(find.text('Faster trip detection'), findsOneWidget);

    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text('Install 1.2.0?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Install').last);
    await tester.pumpAndSettle();
    expect(calls, contains('install'));
  });

  testWidgets('downloading: shows progress instead of buttons', (tester) async {
    await pumpCard(tester, status(available: 12, progress: 0.42));
    expect(find.text('Downloading 1.2.0… 42%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('without install permission: offers to allow it', (tester) async {
    await pumpCard(
      tester,
      status(installPermission: false, silentInstall: false),
    );
    expect(
      find.textContaining('Allow Legacy Tracker to install apps'),
      findsOneWidget,
    );
    await tester.tap(find.text('Allow'));
    await tester.pump();
    expect(calls, contains('openInstallSettings'));
  });

  testWidgets('failed check: shows the error', (tester) async {
    await pumpCard(tester, status(lastError: 'Update check failed: HTTP 503'));
    expect(find.text('Update check failed: HTTP 503'), findsOneWidget);
  });

  testWidgets('failed download: shows the error with the version', (
    tester,
  ) async {
    await pumpCard(
      tester,
      status(available: 12, lastError: 'Download failed: checksum mismatch'),
    );
    expect(
      find.text('Version 1.2.0: Download failed: checksum mismatch'),
      findsOneWidget,
    );
  });

  testWidgets('renders nothing where the app cannot update itself', (
    tester,
  ) async {
    AppUpdater.debugSupportedOverride = false;
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppUpdatesCard())),
    );
    expect(find.byType(Card), findsNothing);
  });
}
