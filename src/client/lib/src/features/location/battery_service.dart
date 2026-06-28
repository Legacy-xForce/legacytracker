import 'dart:async';

import 'package:battery_plus/battery_plus.dart';

/// Immutable snapshot of the device's battery at a point in time.
class BatterySnapshot {
  const BatterySnapshot({this.level, this.isCharging});

  /// Charge level 0–100, or null when unavailable.
  final int? level;

  /// Whether the device is on power (charging or plugged-in-and-full), or null
  /// when unavailable.
  final bool? isCharging;

  static const unavailable = BatterySnapshot();
}

/// Reads the device battery level and charging state via `battery_plus`.
///
/// Every method degrades gracefully: on platforms or conditions where the
/// battery cannot be read (e.g. desktop without a battery), it returns
/// [BatterySnapshot.unavailable] instead of throwing, so callers can simply
/// omit the data from their payload.
class BatteryService {
  BatteryService({Battery? battery}) : _battery = battery ?? Battery();

  final Battery _battery;

  Future<BatterySnapshot> read() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      return BatterySnapshot(
        level: level.clamp(0, 100),
        isCharging: _isOnPower(state),
      );
    } catch (_) {
      return BatterySnapshot.unavailable;
    }
  }

  /// Emits whenever the charging state changes (plugged in/out, full). Level
  /// changes are not pushed by the platform, so callers should also poll
  /// periodically via [read]. Typed as `void` so callers don't depend on the
  /// underlying plugin's enum.
  Stream<void> get onChanged => _battery.onBatteryStateChanged;

  /// Treat both actively charging and plugged-in-while-full as "on power" so the
  /// UI keeps showing the charging indicator once the battery tops out.
  static bool _isOnPower(BatteryState state) =>
      state == BatteryState.charging || state == BatteryState.full;
}
