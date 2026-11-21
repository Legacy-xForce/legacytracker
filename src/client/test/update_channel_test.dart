import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/features/updates/update_channel.dart';
import 'package:legacytracker/src/features/updates/update_channel_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('parses stored channel names, defaulting to stable', () {
    expect(UpdateChannel.parse(null), UpdateChannel.stable);
    expect(UpdateChannel.parse('stable'), UpdateChannel.stable);
    expect(UpdateChannel.parse('nightly'), UpdateChannel.nightly);
    expect(UpdateChannel.parse('something else'), UpdateChannel.stable);
  });

  test('loads the saved channel on this device', () async {
    SharedPreferences.setMockInitialValues({
      UpdateChannelSettings.storageKey: 'nightly',
    });
    final loaded = Completer<void>();
    final settings = UpdateChannelSettings();
    settings.addListener(() {
      if (!loaded.isCompleted) loaded.complete();
    });
    await loaded.future.timeout(const Duration(seconds: 2));
    expect(settings.channel, UpdateChannel.nightly);
  });

  test('saves a new channel and reconfigures the updater', () async {
    final reconfigured = <String>[];
    final settings = UpdateChannelSettings(
      onChanged: (channel) async => reconfigured.add(channel.name),
    );
    await settings.setChannel(UpdateChannel.nightly);

    expect(settings.channel, UpdateChannel.nightly);
    expect(reconfigured, ['nightly']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(UpdateChannelSettings.storageKey), 'nightly');

    // Picking the same channel again is a no-op.
    await settings.setChannel(UpdateChannel.nightly);
    expect(reconfigured, ['nightly']);
  });

  testWidgets('the selector switches channels from the profile', (
    tester,
  ) async {
    final reconfigured = <String>[];
    final settings = UpdateChannelSettings(
      onChanged: (channel) async => reconfigured.add(channel.name),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<UpdateChannelSettings>.value(
          value: settings,
          child: const Scaffold(body: UpdateChannelCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Update channel'), findsOneWidget);
    expect(find.text('Stable'), findsOneWidget);
    expect(find.text('Nightly'), findsOneWidget);
    expect(
      find.text('Published releases, rolled out to everyone.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Nightly'));
    await tester.pumpAndSettle();

    expect(reconfigured, ['nightly']);
    expect(
      find.text('Unreleased builds from main, replaced on every CI run.'),
      findsOneWidget,
    );
  });
}
