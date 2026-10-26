import 'package:flutter/material.dart';

import 'tracking_map_layer.dart';

/// Shared map chrome. Mapbox styles live on the map widget itself (see
/// [MapboxStyles]); this file only holds the floating controls every map
/// screen shows.

/// A floating card holding a column of map buttons, separated by hairlines,
/// so related controls read as one group instead of a stack of FABs.
class MapControlGroup extends StatelessWidget {
  const MapControlGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 4,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              SizedBox(
                width: 28,
                child: Divider(height: 1, color: scheme.outlineVariant),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class MapControlButton extends StatelessWidget {
  const MapControlButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: color),
      style: IconButton.styleFrom(
        fixedSize: const Size.square(48),
        shape: const RoundedRectangleBorder(),
      ),
    );
  }
}

/// Switches [MapLayer]; shared by every map screen. Meant to sit inside a
/// [MapControlGroup].
class MapLayerButton extends StatelessWidget {
  const MapLayerButton({
    super.key,
    required this.selectedLayer,
    required this.onLayerSelected,
  });

  final MapLayer selectedLayer;
  final ValueChanged<MapLayer> onLayerSelected;

  static const _options = [
    (MapLayer.standard, 'Standard', Icons.map_outlined),
    (MapLayer.satellite, 'Satellite', Icons.satellite_alt_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<MapLayer>(
      tooltip: 'Map style',
      initialValue: selectedLayer,
      onSelected: onLayerSelected,
      position: PopupMenuPosition.under,
      offset: const Offset(-8, 4),
      style: IconButton.styleFrom(
        fixedSize: const Size.square(48),
        shape: const RoundedRectangleBorder(),
      ),
      icon: const Icon(Icons.layers_outlined),
      itemBuilder: (context) => [
        for (final (layer, label, icon) in _options)
          PopupMenuItem<MapLayer>(
            value: layer,
            child: Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 12),
                Expanded(child: Text(label)),
                if (layer == selectedLayer)
                  Icon(Icons.check_rounded, size: 18, color: scheme.primary),
              ],
            ),
          ),
      ],
    );
  }
}
