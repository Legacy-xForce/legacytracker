import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/core/theme.dart';
import 'package:legacytracker/src/features/tracking/widgets/user_avatar.dart';

double contrast(Color a, Color b) {
  final hi = a.computeLuminance();
  final lo = b.computeLuminance();
  return (hi > lo ? hi + 0.05 : lo + 0.05) / (hi > lo ? lo + 0.05 : hi + 0.05);
}

void main() {
  group('avatar initials', () {
    for (final color in [...avatarPalette, Colors.grey.shade600]) {
      test('read on #${color.toARGB32().toRadixString(16)}', () {
        expect(
          contrast(initialColorFor(color), color),
          greaterThanOrEqualTo(4.5),
        );
      });
    }

    test('picks the dark initial on light backgrounds', () {
      expect(initialColorFor(Colors.amber), const Color(0xFF1B1B1B));
      expect(initialColorFor(const Color(0xFF0D47A1)), Colors.white);
    });
  });

  group('status chips and banners', () {
    // Chip and banner text is on-surface; the accent only tints the fill.
    final accents = {
      'amber': (Colors.amber, 0.12),
      'blueGrey': (Colors.blueGrey, 0.14),
      'live red': (const Color(0xFFFF453A), 0.16),
    };
    for (final option in appThemes) {
      final scheme = buildThemeFor(option.id).colorScheme;
      for (final entry in accents.entries) {
        test('${option.label}: ${entry.key} tint', () {
          final (accent, alpha) = entry.value;
          final fill = Color.alphaBlend(
            accent.withValues(alpha: alpha),
            scheme.surfaceContainerLow,
          );
          expect(contrast(scheme.onSurface, fill), greaterThanOrEqualTo(4.5));
        });
      }
    }
  });
}
