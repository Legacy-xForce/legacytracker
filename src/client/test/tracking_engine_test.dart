import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/features/location/tracking_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('legacytracker/tracking');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    TrackingEngine.debugSupportedOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('TrackingStatus.fromMap', () {
    test('parses the native status map', () {
      final status = TrackingStatus.fromMap({
        'mode': 'moving',
        'configured': true,
        'live': true,
        'pending': 12,
        'lastUploadAt': 1_759_400_000_000,
        'stationarySince': 1_759_300_000_000,
        'backgroundLocation': false,
        'batteryOptimizationIgnored': false,
      });
      expect(status.mode, TrackingMode.moving);
      expect(status.live, isTrue);
      expect(status.pending, 12);
      expect(
        status.lastUploadAt,
        DateTime.fromMillisecondsSinceEpoch(1_759_400_000_000),
      );
      expect(status.backgroundLocation, isFalse);
      expect(status.batteryOptimizationIgnored, isFalse);
      // Absent permission flags default to "fine" rather than raising alarms.
      expect(status.preciseLocation, isTrue);
    });

    test('unknown or missing values fall back safely', () {
      final status = TrackingStatus.fromMap({'mode': 'warp'});
      expect(status.mode, TrackingMode.off);
      expect(status.pending, 0);
      expect(status.lastUploadAt, isNull);
    });
  });

  test('location events become map points', () {
    final fix = TrackingFix.fromMap({
      'lat': 45.07,
      'lon': 7.68,
      'time': 1_759_400_000_000,
      'accuracy': 4.5,
      'speed': 12.0,
      'heading': null,
    });
    final point = fix.toLocationPoint();
    expect(point.latitude, 45.07);
    expect(point.speed, 12.0);
    expect(point.heading, isNull);
    expect(point.timestamp, DateTime.fromMillisecondsSinceEpoch(1_759_400_000_000));
  });

  test('configure sends what the native engine expects', () async {
    TrackingEngine.debugSupportedOverride = true;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    await TrackingEngine.configure(
      baseUrl: 'https://tracker.example',
      authHeader: 'Device abc',
      userId: 'user-1',
    );
    await TrackingEngine.stop(clearData: true);

    expect(calls.map((c) => c.method), ['configure', 'stop']);
    expect(calls[0].arguments, {
      'baseUrl': 'https://tracker.example',
      'authHeader': 'Device abc',
      'userId': 'user-1',
      'batterySaver': false,
    });
    expect(calls[1].arguments, {'clearData': true});
  });

  test('configure passes deviceId; engine headers come back', () async {
    TrackingEngine.debugSupportedOverride = true;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      // The engine kept its rotated token: configure and stop both report it.
      return 'Device rotated';
    });

    final effective = await TrackingEngine.configure(
      baseUrl: 'https://tracker.example',
      authHeader: 'Device abc',
      userId: 'user-1',
      deviceId: 'dev-1',
    );
    final discarded = await TrackingEngine.stop(clearData: true);

    expect(calls[0].arguments, {
      'baseUrl': 'https://tracker.example',
      'authHeader': 'Device abc',
      'userId': 'user-1',
      'batterySaver': false,
      'deviceId': 'dev-1',
    });
    expect(effective, 'Device rotated');
    expect(discarded, 'Device rotated');
  });

  test('calls are no-ops without a native side', () async {
    TrackingEngine.debugSupportedOverride = false;
    await TrackingEngine.start();
    final status = await TrackingEngine.status();
    expect(status.mode, TrackingMode.off);
    expect(await TrackingEngine.logs(), isEmpty);
  });

  test('missing plugin is tolerated', () async {
    TrackingEngine.debugSupportedOverride = true;
    // No mock handler registered: the call throws MissingPluginException.
    await TrackingEngine.setAppVisible(true);
    final status = await TrackingEngine.status();
    expect(status.configured, isFalse);
  });
}
