import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../map_settings.dart';
import '../map_variant.dart';

/// The "Map lighting" card in the profile tab: the same variant selector the
/// web's appearance dialog has - Auto follows the time of day, the rest pin
/// one of Mapbox Standard's four presets. Saved on this device only.
class MapVariantCard extends StatelessWidget {
  const MapVariantCard({super.key});

  static const _icons = {
    MapVariant.auto: Icons.brightness_auto_rounded,
    MapVariant.dawn: Icons.wb_twilight_rounded,
    MapVariant.day: Icons.light_mode_rounded,
    MapVariant.dusk: Icons.cloud_rounded,
    MapVariant.night: Icons.dark_mode_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<MapSettings>();
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Map lighting. Auto follows the time of day. '
              'Saved on this device only.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final variant in MapVariant.values)
                  _VariantPill(
                    icon: _icons[variant]!,
                    label: variant.label,
                    selected: settings.mapVariant == variant,
                    onTap: () => settings.setMapVariant(variant),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VariantPill extends StatelessWidget {
  const _VariantPill({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      selected: selected,
      label: '$label map lighting',
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
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
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: selected
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.check_rounded, size: 17, color: scheme.primary),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
