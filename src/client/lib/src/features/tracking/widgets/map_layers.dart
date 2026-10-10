import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'tracking_map_layer.dart';

/// Tile layers for the given [layer], shared by every map screen so terrain
/// switching stays consistent across live tracking and replay.
List<Widget> buildMapTileLayers(MapLayer layer) {
  switch (layer) {
    case MapLayer.satellite:
      return [
        TileLayer(
          urlTemplate:
              'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: 'com.example.legacytracker',
        ),
        TileLayer(
          urlTemplate:
              'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: 'com.example.legacytracker',
        ),
      ];
    case MapLayer.terrain:
      return [
        TileLayer(
          urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.example.legacytracker',
        ),
      ];
    case MapLayer.standard:
      return [
        TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.example.legacytracker',
        ),
      ];
  }
}

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

/// Switches [MapLayer]; shared by every map screen that offers terrain
/// switching. Meant to sit inside a [MapControlGroup].
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
    (MapLayer.terrain, 'Terrain', Icons.terrain_outlined),
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
          PopupMenuItem(
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
