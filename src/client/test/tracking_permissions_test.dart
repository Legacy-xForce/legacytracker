import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/features/location/tracking_permissions.dart';
import 'package:legacytracker/src/features/updates/app_updater.dart';

const _askedOnBuildKey = 'lt_perm_asked_on_build';
const _activityAskedKey = 'lt_perm_activity_asked';
const _batteryAskedKey = 'lt_perm_battery_asked';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('legacytracker/updates');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Reports [build] as the installed build, the way the native self-updater
  /// does through `AppUpdater.status()`.
  void installedBuild(int build) {
    AppUpdater.debugSupportedOverride = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'status') return null;
      return <String, Object?>{'currentVersionCode': build};
    });
  }

  tearDown(() {
    AppUpdater.debugSupportedOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('an update re-arms the one-shot dialogs', () async {
    installedBuild(18);
    SharedPreferences.setMockInitialValues({
      _askedOnBuildKey: 17,
      _activityAskedKey: true,
      _batteryAskedKey: true,
    });
    final prefs = await SharedPreferences.getInstance();

    await TrackingPermissions.rearmOnNewBuild(prefs);

    expect(prefs.getInt(_askedOnBuildKey), 18);
    expect(prefs.getBool(_activityAskedKey), isNull);
    expect(prefs.getBool(_batteryAskedKey), isNull);
  });

  test('a fresh install is treated as a new build', () async {
    installedBuild(18);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await TrackingPermissions.rearmOnNewBuild(prefs);

    expect(prefs.getInt(_askedOnBuildKey), 18);
  });

  test('relaunching the same build does not ask again', () async {
    installedBuild(18);
    SharedPreferences.setMockInitialValues({
      _askedOnBuildKey: 18,
      _activityAskedKey: true,
      _batteryAskedKey: true,
    });
    final prefs = await SharedPreferences.getInstance();

    await TrackingPermissions.rearmOnNewBuild(prefs);

    expect(prefs.getBool(_activityAskedKey), isTrue);
    expect(prefs.getBool(_batteryAskedKey), isTrue);
  });

  test('without a reported build number nothing changes', () async {
    // Off Android the updater channel answers nothing at all.
    AppUpdater.debugSupportedOverride = false;
    SharedPreferences.setMockInitialValues({
      _askedOnBuildKey: 17,
      _batteryAskedKey: true,
    });
    final prefs = await SharedPreferences.getInstance();

    await TrackingPermissions.rearmOnNewBuild(prefs);

    expect(prefs.getInt(_askedOnBuildKey), 17);
    expect(prefs.getBool(_batteryAskedKey), isTrue);
  });
}
