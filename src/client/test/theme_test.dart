import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/core/theme.dart';
import 'package:legacytracker/src/core/tokens.dart';
import 'package:legacytracker/src/core/theme_settings.dart';
import 'package:legacytracker/src/features/tracking/widgets/appearance_card.dart';

void main() {
  test('the app bar title is the M3 titleLarge', () {
    final title = buildThemeFor(appThemes.first.id).appBarTheme.titleTextStyle!;
    expect(title.fontSize, 22);
    expect(title.height, closeTo(28 / 22, 1e-9));
  });

  test('feature code takes fixed colours from AppPalette, not literals', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      if (file.path.endsWith('core/theme.dart') ||
          file.path.endsWith('core/palette.dart') ||
          file.path.endsWith('main_mapcheck.dart')) {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (RegExp(r'Color\(0x|\bColors\.[a-z]').hasMatch(lines[i]) &&
            !lines[i].contains('int.parse')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('no text size is written outside the theme and token files', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      if (file.path.endsWith('core/theme.dart') ||
          file.path.endsWith('core/tokens.dart')) {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (RegExp(r'fontSize:\s*[0-9]').hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('the shape scale follows Material 3', () {
    expect(
      [
        AppShape.noneDp,
        AppShape.xsDp,
        AppShape.smDp,
        AppShape.mdDp,
        AppShape.lgDp,
        AppShape.xlDp,
        AppShape.fullDp,
      ],
      [0, 4, 8, 12, 16, 28, 999],
    );
  });

  test('component themes take their corners and heights from the tokens', () {
    for (final option in appThemes) {
      final data = buildThemeFor(option.id);
      expect(data.extension<AppTokens>(), isNotNull);
      expect(
        (data.cardTheme.shape as RoundedRectangleBorder).borderRadius,
        AppShape.md,
      );
      expect(
        (data.dialogTheme.shape as RoundedRectangleBorder).borderRadius,
        AppShape.xl,
      );
      expect(data.navigationBarTheme.height, 80);
    }
  });

  test('every shipped theme builds with its own brightness', () {
    for (final option in appThemes) {
      final data = buildThemeFor(option.id);
      expect(
        data.colorScheme.brightness,
        option.brightness,
        reason: '${option.label} should be ${option.brightness}',
      );
      expect(data.scaffoldBackgroundColor, data.colorScheme.surface);
    }
  });

  test('OLED Adaptive keeps the black surfaces under the phone accents', () {
    final phone = ColorScheme.fromSeed(
      seedColor: Colors.purple,
      brightness: Brightness.dark,
    );
    final scheme = oledSurfaces(phone);

    expect(scheme.surface, const Color(0xFF000000));
    expect(scheme.surfaceContainerLowest, const Color(0xFF000000));
    expect(scheme.primary, phone.primary);
    expect(scheme.secondaryContainer, phone.secondaryContainer);
    expect(scheme.error, phone.error);
  });

  test('teal is the default', () {
    SharedPreferences.setMockInitialValues({});
    expect(ThemeSettings().themeId, AppThemeId.teal);
  });

  test('the chosen theme survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    await ThemeSettings().setTheme(AppThemeId.catppuccinLatte);

    final reopened = ThemeSettings();
    await Future<void>.delayed(Duration.zero);
    expect(reopened.themeId, AppThemeId.catppuccinLatte);
  });

  test('ignores an unknown stored value', () async {
    SharedPreferences.setMockInitialValues({
      ThemeSettings.storageKey: 'solarized',
    });
    final settings = ThemeSettings();
    await Future<void>.delayed(Duration.zero);
    expect(settings.themeId, AppThemeId.teal);
  });

  testWidgets('the appearance pills switch themes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = ThemeSettings();

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeSettings>.value(
        value: settings,
        child: MaterialApp(
          theme: buildThemeFor(AppThemeId.teal),
          home: const Scaffold(
            body: SingleChildScrollView(child: AppearanceCard()),
          ),
        ),
      ),
    );

    expect(find.text('Teal'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.tap(find.text('Mocha'));
    await tester.pump();

    expect(settings.themeId, AppThemeId.catppuccinMocha);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });
}
