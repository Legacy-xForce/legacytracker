import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../data/models/checkpoint.dart';
import '../../data/network/checkpoint_service.dart';
import '../tracking/widgets/tracking_map_layer.dart';
import 'checkpoint_editor_screen.dart';
import 'checkpoints_provider.dart';

class CheckpointsScreen extends StatefulWidget {
  const CheckpointsScreen({
    super.key,
    this.initialCenter,
    this.mapLayer = MapLayer.standard,
  });

  /// Where a new checkpoint's picker opens (usually the user's own position).
  final LatLng? initialCenter;
  final MapLayer mapLayer;

  @override
  State<CheckpointsScreen> createState() => _CheckpointsScreenState();
}

class _CheckpointsScreenState extends State<CheckpointsScreen> {
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Others may have added or renamed checkpoints since the last refresh.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<CheckpointsProvider>().refresh();
    });
  }

  Future<void> _open({Checkpoint? checkpoint}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CheckpointEditorScreen(
          checkpoint: checkpoint,
          initialCenter: widget.initialCenter,
          mapLayer: widget.mapLayer,
        ),
      ),
    );
  }

  Future<void> _delete(Checkpoint checkpoint) async {
    final provider = context.read<CheckpointsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete checkpoint?'),
        content: Text(
          '"${checkpoint.name}" will be removed for everyone. Locations '
          'inside it go back to showing the street name.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 40),
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await provider.delete(checkpoint.id);
    } on CheckpointException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CheckpointsProvider>();
    final theme = Theme.of(context);
    final needle = _query.trim().toLowerCase();
    final visible = [
      for (final c in provider.checkpoints)
        if (needle.isEmpty || c.name.toLowerCase().contains(needle)) c,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Checkpoints')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Add checkpoint'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search checkpoints',
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: provider.refresh,
              child: _body(provider, visible, theme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    CheckpointsProvider provider,
    List<Checkpoint> visible,
    ThemeData theme,
  ) {
    if (visible.isEmpty) {
      final message = provider.isLoading && provider.checkpoints.isEmpty
          ? 'Loading…'
          : provider.error != null && provider.checkpoints.isEmpty
          ? provider.error!
          : provider.checkpoints.isEmpty
          ? 'No checkpoints yet. Add one to see its name instead of the street '
                'when someone is there.'
          : 'No checkpoints match your search.';
      // Scrollable so pull-to-refresh works on an empty list.
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final checkpoint = visible[index];
        return ListTile(
          leading: const Icon(Icons.place_rounded),
          title: Text(checkpoint.name),
          subtitle: Text('${checkpoint.radiusM} m radius'),
          trailing: checkpoint.canEdit
              ? IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _delete(checkpoint),
                )
              : null,
          // Everyone can look at a checkpoint; the editor is read-only
          // for ones they can't change.
          onTap: () => _open(checkpoint: checkpoint),
        );
      },
    );
  }
}
