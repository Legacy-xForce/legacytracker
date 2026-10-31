import 'dart:ui';

/// Every colour that is not derived from the theme's [ColorScheme]: fixed
/// status accents, identity colours and map-bitmap colours, in one place. The
/// web app's `palette.ts` and the status tokens in `style.css` carry the same
/// values, so a person or event looks the same on both.
abstract final class AppPalette {
  // Primitives.
  static const white = Color(0xFFFFFFFF);
  static const black = Color(0xFF000000);
  static const transparent = Color(0x00000000);

  // Status accents, the same in every theme.
  static const online = Color(0xFF34C759);
  static const arrival = Color(0xFFFF453A);
  static const beam = Color(0xFF0985FB);
  static const paused = Color(0xFFFFC107);
  static const hidden = Color(0xFF607D8B);
  static const missing = Color(0xFFFF5252);
  static const battery = Color(0xFF64FFDA);

  // People who haven't been heard from in a while.
  static const stale = Color(0xFF9E9E9E);
  static const staleDark = Color(0xFF757575);
  static const staleBadge = Color(0xFF616161);

  /// A stable colour per user (see `userColor`). The initial on top is white or
  /// near-black, whichever contrasts at least 4.5:1.
  static const avatars = <Color>[
    Color(0xFF1E88E5), // blue
    Color(0xFF8E24AA), // purple
    Color(0xFFF4511E), // deep orange
    Color(0xFF00796B), // teal
    Color(0xFFD81B60), // pink
    Color(0xFF43A047), // green
    Color(0xFF3949AB), // indigo
    Color(0xFFEF6C00), // orange
    Color(0xFF6D4C41), // brown
    Color(0xFF00838F), // cyan
  ];

  static const onAvatarDark = Color(0xFF1B1B1B);

  /// Calendar events without a colour of their own.
  static const eventFallback = Color(0xFF7C4DFF);

  /// Route speed: red at a standstill through orange and yellow to green.
  static const speedStops = <(double, Color)>[
    (0, Color(0xFFF44336)),
    (0.35, Color(0xFFFF9800)),
    (0.65, Color(0xFFFFEB3B)),
    (1, Color(0xFF4CAF50)),
  ];

  /// Podium: gold, silver, bronze; and the text on them.
  static const medals = <Color>[
    Color(0xFFF5C542),
    Color(0xFFC0C7CC),
    Color(0xFFD08B54),
  ];
  static const onMedal = Color(0xFF1A1300);

  // Connection banner.
  static const offlineBanner = Color(0xFFC62828);
  static const onOfflineBanner = white;
  static const poorBanner = Color(0xFFFFC928);
  static const onPoorBanner = Color(0xFF2B2100);

  // Map bitmaps, which have no theme to read.
  static const selfPill = Color(0xFF00695C);
  static const peerPill = Color(0xFF212121);
  static const chip = Color(0xFF2B3134);
  static const nameChip = Color(0xEB252B2A);
  /// Top-of-map scrim behind the status bar.
  static const scrimTop = Color(0x99000000);
  static const mapAccent = Color(0xFF82D5C8);
}
