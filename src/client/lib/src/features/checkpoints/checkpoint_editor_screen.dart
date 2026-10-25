import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../data/models/checkpoint.dart';
import '../../data/network/checkpoint_service.dart';
import '../../data/network/mapbox_token_service.dart';
import '../../data/network/place_search_service.dart';
import '../auth/auth_provider.dart';
import '../tracking/widgets/tracking_map_layer.dart';
import 'checkpoints_provider.dart';

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

  late final ValueNotifier<LatLng> _center;
  MapboxMap? _map;
  MapboxTokenService? _tokenService;
  String? _token;
  int _mapKey = 0;
  CircleAnnotationManager? _circleManager;
  double _radius = 100;
  Timer? _debounce;
  Timer? _tokenTimer;
  List<PlaceResult> _results = const [];
  bool _searching = false;
  String? _searchError;
  bool _saving = false;
  String? _nameError;
  String? _saveError;
  bool _initialized = false;

  bool get _readOnly =>
      widget.checkpoint != null && !widget.checkpoint!.canEdit;

  String _styleUri(MapLayer style) {
    switch (style) {
      case MapLayer.satellite:
        return MapboxStyles.STANDARD_SATELLITE;
      case MapLayer.standard:
      case MapLayer.terrain:
        return MapboxStyles.STANDARD;
      default:
        return MapboxStyles.STANDARD;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final checkpoint = widget.checkpoint;
      _center = ValueNotifier(
        checkpoint?.center ??
            widget.initialCenter ??
            AppConstants.defaultMapCenter,
      );
      _radius = (checkpoint?.radiusM ?? 100).toDouble();
      _nameController.text = checkpoint?.name ?? '';
      _tokenService = MapboxTokenService(
        baseUrl: AppConstants.backendBaseUrl,
        getAccessToken: () => context.read<AuthProvider>().accessToken,
      );
      _initialized = true;
      _refreshToken();
      _tokenTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _refreshToken(),
      );
    }
  }

  Future<void> _refreshToken() async {
    final token = await _tokenService?.token;
    if (!mounted) return;
    if (token != _token) {
      setState(() {
        _token = token;
        _mapKey++;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tokenTimer?.cancel();
    _center.dispose();
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
    setState(() {
      _results = const [];
      _center.value = place.point;
    });
    _map?.setCamera(CameraOptions(
      center: Point(coordinates: Position(place.point.longitude, place.point.latitude)),
      zoom: 17,
    ));
  }

  void _syncCircle() {
    final manager = _circleManager;
    if (manager == null) return;
    final center = _readOnly ? widget.checkpoint!.center : _center.value;
    manager.deleteAll().then((_) async {
      await manager.create(
        CircleAnnotationOptions(
          geometry: Point(
            coordinates: Position(center.longitude, center.latitude),
          ),
          circleColor: 0x330080FF,
          circleRadius: _radius.clamp(4, 40),
          circleOpacity: 0.2,
          circleStrokeColor: 0xFF0080FF,
          circleStrokeWidth: 2,
        ),
      );
    });
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
          latitude: _center.value.latitude,
          longitude: _center.value.longitude,
          radiusM: _radius.round(),
        );
      } else {
        await provider.update(
          existing.id,
          name: name,
          latitude: _center.value.latitude,
          longitude: _center.value.longitude,
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

    if (_token != null) {
      MapboxOptions.setAccessToken(_token!);
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                MapWidget(
                  key: ValueKey(_mapKey),
                  styleUri: _styleUri(widget.mapLayer),
                  cameraOptions: CameraOptions(
                    center: Point(
                      coordinates: Position(
                        _center.value.longitude,
                        _center.value.latitude,
                      ),
                    ),
                    zoom: 16,
                  ),
                  onMapCreated: (map) async {
                    _map = map;
                    _circleManager = await map.annotations
                        .createCircleAnnotationManager();
                    map.setCamera(CameraOptions(
                      center: Point(
                        coordinates: Position(
                          _center.value.longitude,
                          _center.value.latitude,
                        ),
                      ),
                      zoom: 16,
                    ));
                    _syncCircle();
                  },
                  onCameraChangeListener: (event) {
                    if (_readOnly) return;
                    final center = event.cameraState.center;
                    _center.value = LatLng(
                      center.coordinates.lat.toDouble(),
                      center.coordinates.lng.toDouble(),
                    );
                    _syncCircle();
                  },
                  // Interaction options not available in v2; gestures enabled by default.
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
                        : (value) {
                            setState(() => _radius = value);
                            _syncCircle();
                          },
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
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            onChanged: onChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search a street or place',
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
