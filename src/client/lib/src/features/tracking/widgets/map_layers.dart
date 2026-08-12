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

/// The layers menu button used to switch [MapLayer], shared by every map
/// screen that offers terrain switching.
class MapLayerButton extends StatelessWidget {
  const MapLayerButton({
    super.key,
    required this.selectedLayer,
    required this.onLayerSelected,
  });

  final MapLayer selectedLayer;
  final ValueChanged<MapLayer> onLayerSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<MapLayer>(
      initialValue: selectedLayer,
      onSelected: onLayerSelected,
      itemBuilder: (BuildContext context) => const [
        PopupMenuItem(value: MapLayer.standard, child: Text('Standard')),
        PopupMenuItem(value: MapLayer.satellite, child: Text('Satellite')),
        PopupMenuItem(value: MapLayer.terrain, child: Text('Terrain')),
      ],
      child: FloatingActionButton(
        heroTag: 'map_layer_fab',
        mini: true,
        onPressed: null,
        child: const Icon(Icons.layers),
      ),
    );
  }
}
