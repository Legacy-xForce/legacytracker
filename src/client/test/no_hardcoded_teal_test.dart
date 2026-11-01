import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screens take their colours from the theme's [ColorScheme], so a theme
/// switch recolours them. A literal teal in a widget is what once kept the
/// counters, tab switchers and pills teal under Catppuccin.
void main() {
  // Files that may spell a teal out: the default/OLED themes and their
  // fallbacks, fixed status/identity/map-bitmap colours, and the map spike.
  const allowed = {
    'lib/main_mapcheck.dart',
    'lib/src/core/palette.dart',
    'lib/src/core/theme.dart',
  };

  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .where((file) => !allowed.contains(file.path))
      .toList();

  test('scans the app sources', () {
    expect(files.length, greaterThan(50));
  });

  test('uses no Colors.teal / Colors.cyan material swatch', () {
    final pattern = RegExp(
      r'(?<![A-Za-z])Colors\.(?:teal|cyan|tealAccent|cyanAccent)\b',
    );
    final offenders = [
      for (final file in files)
        if (pattern.hasMatch(file.readAsStringSync())) file.path,
    ];
    expect(offenders, isEmpty);
  });

  test('has no teal or cyan Color literal', () {
    final pattern = RegExp(r'Color\(\s*0x([0-9A-Fa-f]{8})\s*\)');
    final offenders = <String>[];
    for (final file in files) {
      for (final match in pattern.allMatches(file.readAsStringSync())) {
        final color = Color(int.parse(match.group(1)!, radix: 16));
        final hsl = HSLColor.fromColor(color);
        if (hsl.hue >= 150 && hsl.hue <= 200 && hsl.saturation >= 0.25) {
          offenders.add('${file.path}: ${match.group(0)}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('palette.dart keeps teal only in the identity colours', () {
    // The avatar palette's teal and cyan are people's colours, the same in
    // every theme; status accents, map pills and the like must not be teal.
    final pattern = RegExp(r'Color\(\s*0x([0-9A-Fa-f]{8})\s*\)');
    final teals = <String>[];
    for (final line in File('lib/src/core/palette.dart').readAsLinesSync()) {
      for (final match in pattern.allMatches(line)) {
        final hsl = HSLColor.fromColor(
          Color(int.parse(match.group(1)!, radix: 16)),
        );
        if (hsl.hue >= 150 && hsl.hue <= 200 && hsl.saturation >= 0.25) {
          teals.add(line.trim());
        }
      }
    }
    expect(teals, ['Color(0xFF00796B), // teal', 'Color(0xFF00838F), // cyan']);
  });
}
