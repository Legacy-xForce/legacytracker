import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tokens.dart';

/// Themes shipped with the app. The teal one is the original look; the
/// Catppuccin flavours and OLED match Legacy Calendar's palette, and the two
/// adaptive themes take their accents from the phone's wallpaper where the
/// platform supports it — Adaptive also follows its light/dark setting, while
/// OLED Adaptive stays pure black.
enum AppThemeId {
  teal,
  oled,
  oledAdaptive,
  catppuccinMocha,
  catppuccinMacchiato,
  catppuccinFrappe,
  catppuccinLatte,
  adaptive,
}

/// Colours used to draw the theme's swatch in the picker.
class AppThemePreview {
  const AppThemePreview({
    required this.canvas,
    required this.raised,
    required this.accent,
    required this.text,
  });

  final Color canvas;
  final Color raised;
  final Color accent;
  final Color text;
}

class AppTheme {
  const AppTheme({
    required this.id,
    required this.label,
    required this.description,
    required this.brightness,
    required this.preview,
  });

  final AppThemeId id;

  /// Short name shown on the pill in the appearance settings.
  final String label;

  /// Full name used in accessibility labels and descriptions.
  final String description;

  /// The brightness of the fixed palette; adaptive themes ignore this and
  /// follow the platform.
  final Brightness brightness;
  final AppThemePreview preview;

  /// Whether the accents come from the phone's own palette (Material You)
  /// rather than the theme's fixed one.
  bool get usesSystemAccents =>
      id == AppThemeId.adaptive || id == AppThemeId.oledAdaptive;

  /// Whether the whole theme follows the platform's light/dark setting. The
  /// background stays pure black whatever the system says, so OLED Adaptive
  /// does not.
  bool get followsSystem => id == AppThemeId.adaptive;
}

const appThemes = <AppTheme>[
  AppTheme(
    id: AppThemeId.teal,
    label: 'Teal',
    description: 'The original Legacy Tracker look',
    brightness: Brightness.dark,
    preview: AppThemePreview(
      canvas: Color(0xFF0E1513),
      raised: Color(0xFF1A2120),
      accent: Color(0xFF82D5C8),
      text: Color(0xFFDDE4E1),
    ),
  ),
  AppTheme(
    id: AppThemeId.oled,
    label: 'OLED',
    description: 'Pure black for OLED screens',
    brightness: Brightness.dark,
    preview: AppThemePreview(
      canvas: Color(0xFF000000),
      raised: Color(0xFF0D1312),
      accent: Color(0xFF82D5C8),
      text: Color(0xFFDDE4E1),
    ),
  ),
  AppTheme(
    id: AppThemeId.oledAdaptive,
    label: 'OLED Adaptive',
    description: "Pure black with your phone's accents",
    brightness: Brightness.dark,
    preview: AppThemePreview(
      canvas: Color(0xFF000000),
      raised: Color(0xFF0D1312),
      accent: Color(0xFF82D5C8),
      text: Color(0xFFDDE4E1),
    ),
  ),
  AppTheme(
    id: AppThemeId.catppuccinMocha,
    label: 'Mocha',
    description: 'Catppuccin Mocha',
    brightness: Brightness.dark,
    preview: AppThemePreview(
      canvas: Color(0xFF1E1E2E),
      raised: Color(0xFF313244),
      accent: Color(0xFFCBA6F7),
      text: Color(0xFFCDD6F4),
    ),
  ),
  AppTheme(
    id: AppThemeId.catppuccinMacchiato,
    label: 'Macchiato',
    description: 'Catppuccin Macchiato',
    brightness: Brightness.dark,
    preview: AppThemePreview(
      canvas: Color(0xFF24273A),
      raised: Color(0xFF363A4F),
      accent: Color(0xFFC6A0F6),
      text: Color(0xFFCAD3F5),
    ),
  ),
  AppTheme(
    id: AppThemeId.catppuccinFrappe,
    label: 'Frappé',
    description: 'Catppuccin Frappé',
    brightness: Brightness.dark,
    preview: AppThemePreview(
      canvas: Color(0xFF303446),
      raised: Color(0xFF414559),
      accent: Color(0xFFCA9EE6),
      text: Color(0xFFC6D0F5),
    ),
  ),
  AppTheme(
    id: AppThemeId.catppuccinLatte,
    label: 'Latte',
    description: 'Catppuccin Latte',
    brightness: Brightness.light,
    preview: AppThemePreview(
      canvas: Color(0xFFEFF1F5),
      raised: Color(0xFFE6E9EF),
      accent: Color(0xFF8839EF),
      text: Color(0xFF4C4F69),
    ),
  ),
  AppTheme(
    id: AppThemeId.adaptive,
    label: 'Adaptive',
    description: 'Follows your phone',
    brightness: Brightness.dark,
    preview: AppThemePreview(
      canvas: Color(0xFF0E1513),
      raised: Color(0xFFEFF1F5),
      accent: Color(0xFF82D5C8),
      text: Color(0xFF4C4F69),
    ),
  ),
];

const defaultAppThemeId = AppThemeId.teal;

AppTheme appThemeFor(AppThemeId id) {
  return appThemes.firstWhere(
    (theme) => theme.id == id,
    orElse: () => appThemes.first,
  );
}

/// The scheme for a fixed palette. Adaptive themes need the platform's
/// brightness (and, when available, its dynamic colours), so callers resolve
/// those through [adaptiveScheme].
ColorScheme schemeFor(AppThemeId id, Brightness brightness) {
  switch (id) {
    case AppThemeId.teal:
    case AppThemeId.adaptive:
      return ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: brightness,
      );
    case AppThemeId.oled:
    case AppThemeId.oledAdaptive:
      // With nothing to adapt to, OLED Adaptive is just OLED; the app layers
      // the phone's accents over these surfaces in its DynamicColorBuilder.
      return _oledScheme();
    case AppThemeId.catppuccinMocha:
      return _catppuccinScheme(_CatppuccinPalette.mocha);
    case AppThemeId.catppuccinMacchiato:
      return _catppuccinScheme(_CatppuccinPalette.macchiato);
    case AppThemeId.catppuccinFrappe:
      return _catppuccinScheme(_CatppuccinPalette.frappe);
    case AppThemeId.catppuccinLatte:
      return _catppuccinScheme(_CatppuccinPalette.latte);
  }
}

/// The fallback for Adaptive when the platform has no dynamic colours.
ColorScheme adaptiveScheme(Brightness brightness) {
  return schemeFor(AppThemeId.adaptive, brightness);
}

ThemeData buildThemeFor(AppThemeId id) {
  final theme = appThemeFor(id);
  final scheme = schemeFor(id, theme.brightness);
  return buildAppTheme(scheme);
}

ThemeData buildAppTheme(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  final rounded16 = RoundedRectangleBorder(
    borderRadius: AppShape.lg,
  );
  final overlayStyle =
      (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: scheme.surface,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      );

  return ThemeData(
    useMaterial3: true,
    extensions: const [AppTokens()],
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: overlayStyle,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: AppShape.md),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: const AppTokens().navigationBarHeight,
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: rounded16,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: AppShape.lg,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppShape.lg,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppShape.lg,
        borderSide: BorderSide(color: scheme.error),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: rounded16,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: AppShape.xl),
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      contentTextStyle: TextStyle(
        fontSize: 14,
        height: 1.4,
        color: scheme.onSurfaceVariant,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: rounded16,
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(fontSize: 14, color: scheme.onSurface),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: scheme.surfaceContainerLow,
      modalBarrierColor: Colors.black.withValues(alpha: dark ? 0.55 : 0.3),
      shape: const RoundedRectangleBorder(borderRadius: AppShape.sheetTop),
      showDragHandle: true,
      dragHandleColor: scheme.outlineVariant,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
  );
}

/// [base] with the OLED's pure-black surface ramp pasted over it. The accents
/// stay whatever [base] was seeded with, which is what lets OLED Adaptive reuse
/// the same black surfaces under the phone's own palette.
ColorScheme oledSurfaces(ColorScheme base) {
  const black = Color(0xFF000000);
  const onSurface = Color(0xFFDDE4E1);
  return base.copyWith(
    surface: black,
    surfaceDim: black,
    surfaceBright: const Color(0xFF1A2120),
    surfaceContainerLowest: black,
    surfaceContainerLow: const Color(0xFF070B0A),
    surfaceContainer: const Color(0xFF0D1312),
    surfaceContainerHigh: const Color(0xFF151C1A),
    surfaceContainerHighest: const Color(0xFF1E2624),
    onSurface: onSurface,
    onSurfaceVariant: const Color(0xFFA8B4B1),
    outline: const Color(0xFF5C6764),
    outlineVariant: const Color(0xFF26302E),
    inverseSurface: onSurface,
    onInverseSurface: const Color(0xFF0E1513),
    surfaceTint: Colors.transparent,
  );
}

ColorScheme _oledScheme() {
  return oledSurfaces(
    ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
  );
}

class _CatppuccinPalette {
  const _CatppuccinPalette({
    required this.isLight,
    required this.base,
    required this.mantle,
    required this.crust,
    required this.surface0,
    required this.surface1,
    required this.surface2,
    required this.overlay0,
    required this.overlay1,
    required this.overlay2,
    required this.subtext0,
    required this.subtext1,
    required this.text,
    required this.mauve,
    required this.red,
    required this.peach,
    required this.green,
    required this.teal,
    required this.lavender,
  });

  final bool isLight;
  final Color base;
  final Color mantle;
  final Color crust;
  final Color surface0;
  final Color surface1;
  final Color surface2;
  final Color overlay0;
  final Color overlay1;
  final Color overlay2;
  final Color subtext0;
  final Color subtext1;
  final Color text;
  final Color mauve;
  final Color red;
  final Color peach;
  final Color green;
  final Color teal;
  final Color lavender;

  Brightness get brightness => isLight ? Brightness.light : Brightness.dark;

  static const mocha = _CatppuccinPalette(
    isLight: false,
    base: Color(0xFF1E1E2E),
    mantle: Color(0xFF181825),
    crust: Color(0xFF11111B),
    surface0: Color(0xFF313244),
    surface1: Color(0xFF45475A),
    surface2: Color(0xFF585B70),
    overlay0: Color(0xFF6C7086),
    overlay1: Color(0xFF7F849C),
    overlay2: Color(0xFF9399B2),
    subtext0: Color(0xFFA6ADC8),
    subtext1: Color(0xFFBAC2DE),
    text: Color(0xFFCDD6F4),
    mauve: Color(0xFFCBA6F7),
    red: Color(0xFFF38BA8),
    peach: Color(0xFFFAB387),
    green: Color(0xFFA6E3A1),
    teal: Color(0xFF94E2D5),
    lavender: Color(0xFFB4BEFE),
  );

  static const macchiato = _CatppuccinPalette(
    isLight: false,
    base: Color(0xFF24273A),
    mantle: Color(0xFF1E2030),
    crust: Color(0xFF181926),
    surface0: Color(0xFF363A4F),
    surface1: Color(0xFF494D64),
    surface2: Color(0xFF5B6078),
    overlay0: Color(0xFF6E738D),
    overlay1: Color(0xFF8087A2),
    overlay2: Color(0xFF939AB7),
    subtext0: Color(0xFFA5ADCB),
    subtext1: Color(0xFFB8C0E0),
    text: Color(0xFFCAD3F5),
    mauve: Color(0xFFC6A0F6),
    red: Color(0xFFED8796),
    peach: Color(0xFFF5A97F),
    green: Color(0xFFA6DA95),
    teal: Color(0xFF8BD5CA),
    lavender: Color(0xFFB7BDF8),
  );

  static const frappe = _CatppuccinPalette(
    isLight: false,
    base: Color(0xFF303446),
    mantle: Color(0xFF292C3C),
    crust: Color(0xFF232634),
    surface0: Color(0xFF414559),
    surface1: Color(0xFF51576D),
    surface2: Color(0xFF626880),
    overlay0: Color(0xFF737994),
    overlay1: Color(0xFF838BA7),
    overlay2: Color(0xFF949CBB),
    subtext0: Color(0xFFA5ADCE),
    subtext1: Color(0xFFB5BFE2),
    text: Color(0xFFC6D0F5),
    mauve: Color(0xFFCA9EE6),
    red: Color(0xFFE78284),
    peach: Color(0xFFEF9F76),
    green: Color(0xFFA6D189),
    teal: Color(0xFF81C8BE),
    lavender: Color(0xFFBABBF1),
  );

  static const latte = _CatppuccinPalette(
    isLight: true,
    base: Color(0xFFEFF1F5),
    mantle: Color(0xFFE6E9EF),
    crust: Color(0xFFDCE0E8),
    surface0: Color(0xFFCCD0DA),
    surface1: Color(0xFFBCC0CC),
    surface2: Color(0xFFACB0BE),
    overlay0: Color(0xFF9CA0B0),
    overlay1: Color(0xFF8C8FA1),
    overlay2: Color(0xFF7C7F93),
    subtext0: Color(0xFF6C6F85),
    subtext1: Color(0xFF5C5F77),
    text: Color(0xFF4C4F69),
    mauve: Color(0xFF8839EF),
    red: Color(0xFFD20F39),
    peach: Color(0xFFFE640B),
    green: Color(0xFF40A02B),
    teal: Color(0xFF179299),
    lavender: Color(0xFF7287FD),
  );
}

ColorScheme _catppuccinScheme(_CatppuccinPalette p) {
  final dark = !p.isLight;
  final onAccent = p.isLight ? p.base : p.crust;
  final primaryContainer = _blend(p.mauve, p.base, dark ? 0.24 : 0.16);
  final secondaryContainer = _blend(p.teal, p.base, dark ? 0.22 : 0.18);
  final tertiaryContainer = _blend(p.peach, p.base, dark ? 0.20 : 0.18);
  final errorContainer = _blend(p.red, p.base, dark ? 0.24 : 0.16);
  final bright = p.isLight ? const Color(0xFFF8F9FB) : p.surface1;

  return ColorScheme(
    brightness: p.brightness,
    primary: p.mauve,
    onPrimary: onAccent,
    primaryContainer: primaryContainer,
    onPrimaryContainer: p.text,
    secondary: p.teal,
    onSecondary: onAccent,
    secondaryContainer: secondaryContainer,
    onSecondaryContainer: p.text,
    tertiary: p.peach,
    onTertiary: onAccent,
    tertiaryContainer: tertiaryContainer,
    onTertiaryContainer: p.text,
    error: p.red,
    onError: onAccent,
    errorContainer: errorContainer,
    onErrorContainer: p.text,
    surface: p.base,
    onSurface: p.text,
    onSurfaceVariant: p.subtext0,
    surfaceDim: p.crust,
    surfaceBright: bright,
    surfaceContainerLowest: p.isLight ? bright : p.crust,
    surfaceContainerLow: p.mantle,
    surfaceContainer: p.isLight ? p.mantle : p.surface0,
    surfaceContainerHigh: p.isLight ? p.crust : p.surface1,
    surfaceContainerHighest: p.isLight ? p.surface0 : p.surface2,
    outline: p.overlay2,
    outlineVariant: p.surface2,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: p.text,
    onInverseSurface: p.base,
    inversePrimary: p.lavender,
    surfaceTint: Colors.transparent,
  );
}

Color _blend(Color foreground, Color background, double alpha) {
  return Color.alphaBlend(foreground.withValues(alpha: alpha), background);
}
