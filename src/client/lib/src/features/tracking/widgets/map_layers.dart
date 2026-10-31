import 'package:flutter/material.dart';

import 'tracking_map_layer.dart';
import '../../../core/tokens.dart';
import '../../../core/palette.dart';

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
      elevation: 2,
      shadowColor: AppPalette.black.withValues(alpha: 0.54),
      borderRadius: AppShape.lg,
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

/// Opens the layers sheet from the bottom of the screen: map type, how the map
/// may be turned and tilted, and what is drawn on it.
Future<void> showMapLayersSheet(
  BuildContext context, {
  required MapLayer selectedLayer,
  required ValueChanged<MapLayer> onLayerSelected,
  required bool orientationLocked,
  required ValueChanged<bool> onOrientationLockChanged,
  required bool view3d,
  required ValueChanged<bool> onView3dChanged,
  bool? showEvents,
  ValueChanged<bool>? onShowEventsChanged,
  bool? showCheckpoints,
  ValueChanged<bool>? onShowCheckpointsChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _MapLayersSheet(
      selectedLayer: selectedLayer,
      onLayerSelected: onLayerSelected,
      orientationLocked: orientationLocked,
      onOrientationLockChanged: onOrientationLockChanged,
      view3d: view3d,
      onView3dChanged: onView3dChanged,
      showEvents: showEvents,
      onShowEventsChanged: onShowEventsChanged,
      showCheckpoints: showCheckpoints,
      onShowCheckpointsChanged: onShowCheckpointsChanged,
    ),
  );
}

class _MapLayersSheet extends StatefulWidget {
  const _MapLayersSheet({
    required this.selectedLayer,
    required this.onLayerSelected,
    required this.orientationLocked,
    required this.onOrientationLockChanged,
    required this.view3d,
    required this.onView3dChanged,
    this.showEvents,
    this.onShowEventsChanged,
    this.showCheckpoints,
    this.onShowCheckpointsChanged,
  });

  final MapLayer selectedLayer;
  final ValueChanged<MapLayer> onLayerSelected;
  final bool orientationLocked;
  final ValueChanged<bool> onOrientationLockChanged;
  final bool view3d;
  final ValueChanged<bool> onView3dChanged;
  final bool? showEvents;
  final ValueChanged<bool>? onShowEventsChanged;
  final bool? showCheckpoints;
  final ValueChanged<bool>? onShowCheckpointsChanged;

  @override
  State<_MapLayersSheet> createState() => _MapLayersSheetState();
}

class _MapLayersSheetState extends State<_MapLayersSheet> {
  // The sheet stays open while switches are flipped, so it keeps its own copy
  // of what the caller owns.
  late MapLayer _layer = widget.selectedLayer;
  late bool _locked = widget.orientationLocked;
  late bool _view3d = widget.view3d;
  late bool? _events = widget.showEvents;
  late bool? _checkpoints = widget.showCheckpoints;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Map type', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final (layer, label, icon) in MapLayerButton._options)
                  Expanded(
                    child: _LayerChoice(
                      label: label,
                      icon: icon,
                      selected: layer == _layer,
                      onTap: () {
                        setState(() => _layer = layer);
                        widget.onLayerSelected(layer);
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.explore_outlined),
              title: const Text('Lock orientation'),
              subtitle: const Text('Keep north at the top'),
              value: _locked,
              onChanged: (value) {
                setState(() => _locked = value);
                widget.onOrientationLockChanged(value);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.view_in_ar_outlined),
              title: const Text('3D view'),
              subtitle: const Text('Tilt the map so buildings stand up'),
              value: _view3d,
              onChanged: (value) {
                setState(() => _view3d = value);
                widget.onView3dChanged(value);
              },
            ),
            if (_events != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.event_rounded),
                title: const Text('Events'),
                value: _events!,
                onChanged: (value) {
                  setState(() => _events = value);
                  widget.onShowEventsChanged?.call(value);
                },
              ),
            if (_checkpoints != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.place_rounded),
                title: const Text('Saved places'),
                value: _checkpoints!,
                onChanged: (value) {
                  setState(() => _checkpoints = value);
                  widget.onShowCheckpointsChanged?.call(value);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _LayerChoice extends StatelessWidget {
  const _LayerChoice({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: AppShape.lg,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: selected
                    ? scheme.secondaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: AppShape.lg,
                border: Border.all(
                  color: selected ? scheme.primary : AppPalette.transparent,
                  width: 2,
                ),
              ),
              child: Icon(
                icon,
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: selected ? scheme.primary : null,
                fontWeight: selected ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
