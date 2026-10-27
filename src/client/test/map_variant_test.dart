import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/features/tracking/map_variant.dart';

/// The variant resolution must match the web's `styles.ts` exactly: same
/// time bands, same satellite dimming factors, so one preference looks the
/// same in both clients.
void main() {
  group('presetForTime', () {
    test('follows the web bands', () {
      expect(presetForTime(DateTime(2026, 10, 27, 4, 59)), MapLightPreset.night);
      expect(presetForTime(DateTime(2026, 10, 27, 5)), MapLightPreset.dawn);
      expect(presetForTime(DateTime(2026, 10, 27, 7, 59)), MapLightPreset.dawn);
      expect(presetForTime(DateTime(2026, 10, 27, 8)), MapLightPreset.day);
      expect(presetForTime(DateTime(2026, 10, 27, 16, 59)), MapLightPreset.day);
      expect(presetForTime(DateTime(2026, 10, 27, 17)), MapLightPreset.dusk);
      expect(presetForTime(DateTime(2026, 10, 27, 19, 59)), MapLightPreset.dusk);
      expect(presetForTime(DateTime(2026, 10, 27, 20)), MapLightPreset.night);
    });
  });

  group('resolveMapPreset', () {
    test('a fixed variant ignores the clock', () {
      expect(
        resolveMapPreset(MapVariant.dawn, DateTime(2026, 10, 27, 12)),
        MapLightPreset.dawn,
      );
      expect(
        resolveMapPreset(MapVariant.night, DateTime(2026, 10, 27, 12)),
        MapLightPreset.night,
      );
    });

    test('auto follows the clock', () {
      expect(
        resolveMapPreset(MapVariant.auto, DateTime(2026, 10, 27, 12)),
        MapLightPreset.day,
      );
      expect(
        resolveMapPreset(MapVariant.auto, DateTime(2026, 10, 27, 23)),
        MapLightPreset.night,
      );
    });
  });

  group('satelliteLightFor', () {
    test('day leaves the imagery untouched', () {
      final light = satelliteLightFor(MapLightPreset.day);
      expect(light.brightness, 1);
      expect(light.saturation, 0);
    });

    test('night dims and desaturates the most', () {
      final night = satelliteLightFor(MapLightPreset.night);
      final dusk = satelliteLightFor(MapLightPreset.dusk);
      expect(night.brightness, lessThan(dusk.brightness));
      expect(night.saturation, lessThan(dusk.saturation));
      expect(night.brightness, greaterThan(0));
    });
  });
}
