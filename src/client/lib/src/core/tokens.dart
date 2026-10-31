import 'package:flutter/material.dart';

/// Material 3 shape scale (none / xs 4 / sm 8 / md 12 / lg 16 / xl 28 / full).
/// The only place a corner radius is written down; the web's `--radius-*`
/// tokens in `style.css` carry the same values.
abstract final class AppShape {
  static const double noneDp = 0;
  static const double xsDp = 4;
  static const double smDp = 8;
  static const double mdDp = 12;
  static const double lgDp = 16;
  static const double xlDp = 28;
  static const double fullDp = 999;

  static const BorderRadius none = BorderRadius.zero;
  static const BorderRadius xs = BorderRadius.all(Radius.circular(xsDp));
  static const BorderRadius sm = BorderRadius.all(Radius.circular(smDp));
  static const BorderRadius md = BorderRadius.all(Radius.circular(mdDp));
  static const BorderRadius lg = BorderRadius.all(Radius.circular(lgDp));
  static const BorderRadius xl = BorderRadius.all(Radius.circular(xlDp));
  static const BorderRadius full = BorderRadius.all(Radius.circular(fullDp));

  static const Radius xsRadius = Radius.circular(xsDp);
  static const Radius smRadius = Radius.circular(smDp);
  static const Radius mdRadius = Radius.circular(mdDp);
  static const Radius lgRadius = Radius.circular(lgDp);
  static const Radius xlRadius = Radius.circular(xlDp);
  static const Radius fullRadius = Radius.circular(fullDp);

  /// A sheet's top corners.
  static const BorderRadius sheetTop = BorderRadius.vertical(top: xlRadius);
}

/// Material 3 motion: four durations and the standard/emphasized easings. A
/// transition asks for its duration through [AppMotion.of] so it collapses to
/// nothing when the system asks to reduce motion.
abstract final class AppMotion {
  static const short = Duration(milliseconds: 100);
  static const medium = Duration(milliseconds: 200);
  static const long = Duration(milliseconds: 300);
  static const extraLong = Duration(milliseconds: 500);

  /// A loading spinner's revolution; it is not a transition, so it is the one
  /// duration that does not collapse.
  static const spin = Duration(milliseconds: 900);

  static const standard = Cubic(0.2, 0, 0, 1);
  static const emphasized = Curves.easeInOutCubicEmphasized;
  static const emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1);

  /// [duration], or zero when the user turned animations off.
  static Duration of(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
}

/// Material 3 label sizes for text painted onto map bitmaps, where there is no
/// [Theme] to read a [TextTheme] from.
abstract final class AppType {
  static const double labelMd = 12;
  static const double labelSm = 11;
}

/// The design tokens a [ThemeData] carries, for component themes and widgets
/// that read them from the context.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens();

  /// Height of the bottom navigation bar (M3: 80).
  double get navigationBarHeight => 80;

  /// Cards.
  BorderRadius get cardRadius => AppShape.md;

  /// Dialogs, sheets and other large surfaces.
  BorderRadius get largeSurfaceRadius => AppShape.xl;

  static AppTokens of(BuildContext context) =>
      Theme.of(context).extension<AppTokens>() ?? const AppTokens();

  @override
  AppTokens copyWith() => const AppTokens();

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) => this;
}
