import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/core/battery_icon.dart';

void main() {
  test('charging always uses the charging glyph', () {
    for (final level in [0, 10, 55, 90, 100]) {
      expect(batteryIcon(level, true), Icons.battery_charging_full_rounded);
    }
  });

  test('the people list and the map markers use the same level thresholds', () {
    expect(batteryIcon(100, false), Icons.battery_full_rounded);
    expect(batteryIcon(90, false), Icons.battery_full_rounded);
    expect(batteryIcon(89, false), Icons.battery_5_bar_rounded);
    expect(batteryIcon(70, false), Icons.battery_5_bar_rounded);
    expect(batteryIcon(69, false), Icons.battery_4_bar_rounded);
    expect(batteryIcon(55, false), Icons.battery_4_bar_rounded);
    expect(batteryIcon(54, false), Icons.battery_3_bar_rounded);
    expect(batteryIcon(40, false), Icons.battery_3_bar_rounded);
    expect(batteryIcon(39, false), Icons.battery_2_bar_rounded);
    expect(batteryIcon(25, false), Icons.battery_2_bar_rounded);
    expect(batteryIcon(24, false), Icons.battery_1_bar_rounded);
    expect(batteryIcon(10, false), Icons.battery_1_bar_rounded);
    expect(batteryIcon(9, false), Icons.battery_alert_rounded);
    expect(batteryIcon(0, false), Icons.battery_alert_rounded);
  });
}
