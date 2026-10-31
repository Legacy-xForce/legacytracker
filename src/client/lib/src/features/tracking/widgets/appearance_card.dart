import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme.dart';
import '../../../core/theme_settings.dart';
import '../../../core/tokens.dart';

/// "Appearance" card in the profile tab: the same pill row Legacy Calendar
/// uses, so the two apps feel like one product.
class AppearanceCard extends StatelessWidget {
  const AppearanceCard({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeSettings>();
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OLED, Catppuccin or adaptive. Saved on this device only.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in appThemes)
                  ThemePill(
                    theme: option,
                    selected: settings.themeId == option.id,
                    onTap: () => settings.setTheme(option.id),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ThemePill extends StatelessWidget {
  const ThemePill({
    super.key,
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final AppTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.onPrimaryContainer : scheme.onSurface;

    return Semantics(
      button: true,
      selected: selected,
      label: '${theme.description} theme',
      child: Tooltip(
        message: theme.description,
        child: Material(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHigh,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(7, 5, 14, 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ThemeSwatch(theme: theme),
                    const SizedBox(width: 8),
                    Text(
                      theme.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: foreground,
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.check_rounded,
                        size: 17,
                        color: scheme.primary,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.theme});

  final AppTheme theme;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = theme.preview;

    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.followsSystem ? null : preview.canvas,
        gradient: theme.followsSystem
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [preview.canvas, preview.raised],
              )
            : null,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.75),
        ),
      ),
      child: Center(
        // A dot for a theme whose accents come from the phone: its colour is
        // only an example, so the fixed bars would over-claim the palette.
        child: theme.usesSystemAccents
            ? Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: preview.accent,
                  border: Border.all(color: Colors.white70, width: 1.5),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 2.5,
                    decoration: BoxDecoration(
                      color: preview.accent,
                      borderRadius: AppShape.full,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    width: 10,
                    height: 2,
                    decoration: BoxDecoration(
                      color: preview.text.withValues(alpha: 0.8),
                      borderRadius: AppShape.full,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
