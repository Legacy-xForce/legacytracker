import 'package:flutter/material.dart';

/// The battery glyph for a charge level, as the web client picks it.
///
/// The people list and the map markers share this table so one person shows
/// the same glyph in both places.
IconData batteryIcon(int level, bool charging) {
  if (charging) return Icons.battery_charging_full_rounded;
  if (level >= 90) return Icons.battery_full_rounded;
  if (level >= 70) return Icons.battery_5_bar_rounded;
  if (level >= 55) return Icons.battery_4_bar_rounded;
  if (level >= 40) return Icons.battery_3_bar_rounded;
  if (level >= 25) return Icons.battery_2_bar_rounded;
  if (level >= 10) return Icons.battery_1_bar_rounded;
  return Icons.battery_alert_rounded;
}
