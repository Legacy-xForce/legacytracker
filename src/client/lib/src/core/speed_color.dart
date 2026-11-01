import 'dart:ui';

import 'palette.dart';
import 'formatters.dart';

/// Speed (km/h) at which a replay line is fully green.
///
/// Slower speeds fade through amber and yellow, so a stop reads red and a
/// motorway run reads green at a glance.
const double speedColorMaxKmh = 70;

/// Nearby speeds share a colour, so consecutive route segments merge into one
/// polyline instead of redrawing the line for every fix.
const int _speedColorSteps = 16;

/// Colour for a recorded speed in metres per second: red when slow, green when
/// fast. Speeds are clamped to the 0-[speedColorMaxKmh] range.
Color speedColor(double speedMps) {
  final kmh = speedMps.isFinite
      ? msToKmh(speedMps.clamp(0.0, double.infinity))
      : 0.0;
  final ratio = (kmh / speedColorMaxKmh).clamp(0.0, 1.0);
  final step = (ratio * _speedColorSteps).round() / _speedColorSteps;

  var index = 0;
  while (index < AppPalette.speedStops.length - 2 &&
      step > AppPalette.speedStops[index + 1].$1) {
    index++;
  }
  final (start, from) = AppPalette.speedStops[index];
  final (end, to) = AppPalette.speedStops[index + 1];
  final local = end == start ? 0.0 : (step - start) / (end - start);
  return Color.lerp(from, to, local)!;
}
