import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../data/models/checkpoint.dart';
import '../../data/network/checkpoint_service.dart';
import '../../data/network/mapbox_token_gate.dart';
import '../../data/network/mapbox_token_service.dart';
import '../../data/network/place_search_service.dart';
import '../auth/auth_provider.dart';
import '../tracking/map_settings.dart';
import '../tracking/map_variant.dart';
import '../tracking/widgets/mapbox_map.dart';
import '../tracking/widgets/tracking_map_layer.dart';
import 'checkpoints_provider.dart';
import '../../core/tokens.dart';

/// Creates or edits a checkpoint. The point is whatever sits under the
/// crosshair: pan the map, or search for a street and the camera jumps there.
/// A checkpoint the user may not change opens read-only.
class CheckpointEditorScreen extends StatefulWidget {
  const CheckpointEditorScreen({
    super.key,
    this.checkpoint,
    this.initialCenter,
    this.mapLayer = MapLayer.standard,
  });

  final Checkpoint? checkpoint;
  final LatLng? initialCenter;
  final MapLayer mapLayer;

  @override
  State<CheckpointEditorScreen> createState() => _CheckpointEditorScreenState();
}

class _CheckpointEditorScreenState extends State<CheckpointEditorScreen> {
  final _nameController = TextEditingController();
  final _searchController = TextEditingController();
  final _placeSearch = PlaceSearchService();

  late LatLng _center;
  late double _radius;
  MapboxMap? _map;
  MapboxTokenService? _tokenService;
  final MapScene _scene = MapScene();
  String? _sceneSpec;
  bool _initialized = false;

  Timer? _debounce;
  List<PlaceResult> _results = const [];
  bool _searching = false;
  String? _searchError;
  bool _saving = false;
  String? _nameError;
  String? _saveError;

  bool get _readOnly =>
      widget.checkpoint != null && !widget.checkpoint!.canEdit;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final checkpoint = widget.checkpoint;
    _center =
        checkpoint?.center ??
        widget.initialCenter ??
        AppConstants.defaultMapCenter;
    _radius = (checkpoint?.radiusM ?? 100).toDouble();
    _nameController.text = checkpoint?.name ?? '';
    _tokenService = MapboxTokenService(
      baseUrl: AppConstants.backendBaseUrl,
      getAccessToken: () => context.read<AuthProvider>().accessToken,
    );
    _initialized = true;
    _syncScene();
  }

  /// The circle follows the crosshair, which moves on every pan; pushing it
  /// through the scene keeps the map from rebuilding while the user drags.
  void _syncScene() {
    final overlay = MapCheckpointOverlay(
      id: widget.checkpoint?.id ?? 'editor',
      center: _readOnly ? widget.checkpoint!.center : _center,
      radiusMeters: _radius,
      color: Theme.of(context).colorScheme.primary,
    );
    final spec =
        '${overlay.center.latitude},${overlay.center.longitude},'
        '${overlay.radiusMeters},${overlay.color.toARGB32()}';
    if (spec == _sceneSpec) return;
    _sceneSpec = spec;
    _scene.checkpoints = [overlay];
    _scene.markChanged();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scene.dispose();
    _tokenService?.dispose();
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 3) {
      setState(() {
        _results = const [];
        _searchError = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 700), () async {
      setState(() {
        _searching = true;
        _searchError = null;
      });
      try {
        final results = await _placeSearch.search(value);
        if (!mounted || _searchController.text != value) return;
        setState(() {
          _results = results;
          _searchError = results.isEmpty ? 'No places found.' : null;
        });
      } catch (_) {
        if (mounted) setState(() => _searchError = 'Search is unavailable.');
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  void _pick(PlaceResult place) {
    FocusScope.of(context).unfocus();
    setState(() => _results = const []);
    _center = place.point;
    _syncScene();
    _map?.setCamera(
      CameraOptions(
        center: Point(
          coordinates: Position(place.point.longitude, place.point.latitude),
        ),
        zoom: 17,
      ),
    );
  }

  void _onCameraChanged(CameraState state) {
    if (_readOnly) return;
    final center = state.center;
    final next = LatLng(
      center.coordinates.lat.toDouble(),
      center.coordinates.lng.toDouble(),
    );
    if (next.latitude == _center.latitude &&
        next.longitude == _center.longitude) {
      return;
    }
    _center = next;
    _syncScene();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty) {
      setState(() => _nameError = 'Give the checkpoint a name.');
      return;
    }
    final provider = context.read<CheckpointsProvider>();
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _nameError = null;
      _saveError = null;
    });
    try {
      final existing = widget.checkpoint;
      if (existing == null) {
        await provider.create(
          name: name,
          latitude: _center.latitude,
          longitude: _center.longitude,
          radiusM: _radius.round(),
        );
      } else {
        await provider.update(
          existing.id,
          name: name,
          latitude: _center.latitude,
          longitude: _center.longitude,
          radiusM: _radius.round(),
        );
      }
      if (mounted) navigator.pop();
    } on CheckpointException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (e.nameTaken) {
          _nameError = e.message;
        } else {
          _saveError = e.message;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.checkpoint == null
        ? 'New checkpoint'
        : _readOnly
        ? 'Checkpoint'
        : 'Edit checkpoint';
    // Covers the radius slider and any other change that rebuilds this screen.
    _syncScene();

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                MapboxTokenGate(
                  service: _tokenService,
                  builder: (context, session) => MapboxMapWidget(
                    key: ValueKey('checkpoint-map-${session.generation}'),
                    accessToken: session.token,
                    initialCenter: _center,
                    initialZoom: 16,
                    style: widget.mapLayer,
                    lightPreset: resolveMapPreset(
                      context.watch<MapSettings>().mapVariant,
                      DateTime.now(),
                    ),
                    scene: _scene,
                    onCameraChanged: _onCameraChanged,
                    onLoadError: (_) => session.recover(),
                    onMapCreated: (map) {
                      _map = map;
                      map.setCamera(
                        CameraOptions(
                          center: Point(
                            coordinates: Position(
                              _center.longitude,
                              _center.latitude,
                            ),
                          ),
                          zoom: 16,
                        ),
                      );
                    },
                  ),
                ),
                if (!_readOnly)
                  IgnorePointer(
                    child: Center(
                      child: Icon(
                        Icons.add_rounded,
                        size: 28,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                if (!_readOnly)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 12,
                    child: _SearchBox(
                      controller: _searchController,
                      searching: _searching,
                      error: _searchError,
                      results: _results,
                      onChanged: _onSearchChanged,
                      onPick: _pick,
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nameController,
                    enabled: !_readOnly,
                    maxLength: maxCheckpointNameLength,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      counterText: '',
                      errorText: _nameError,
                    ),
                    onChanged: (_) {
                      if (_nameError != null) setState(() => _nameError = null);
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Radius: ${_radius.round()} m',
                    style: theme.textTheme.labelLarge,
                  ),
                  Slider(
                    value: _radius,
                    min: minCheckpointRadiusM.toDouble(),
                    max: maxCheckpointRadiusM.toDouble(),
                    divisions: maxCheckpointRadiusM - minCheckpointRadiusM,
                    label: '${_radius.round()} m',
                    onChanged: _readOnly
                        ? null
                        : (value) => setState(() => _radius = value),
                  ),
                  if (_saveError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _saveError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  if (!_readOnly)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: Text(_saving ? 'Saving…' : 'Save'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.searching,
    required this.error,
    required this.results,
    required this.onChanged,
    required this.onPick,
  });

  final TextEditingController controller;
  final bool searching;
  final String? error;
  final List<PlaceResult> results;
  final ValueChanged<String> onChanged;
  final ValueChanged<PlaceResult> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 4,
      borderRadius: AppShape.lg,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            onChanged: onChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Search a street or place',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
              border: InputBorder.none,
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  error!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          for (final place in results)
            ListTile(
              dense: true,
              leading: const Icon(Icons.place_outlined),
              title: Text(
                place.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onPick(place),
            ),
        ],
      ),
    );
  }
}
