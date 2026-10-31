import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:provider/provider.dart';

import '../../../core/constants.dart';
import '../../../data/models/calendar_event.dart';
import '../../../data/models/checkpoint.dart';
import '../../../data/models/location_model.dart';
import '../../../data/models/map_viewer.dart';
import '../../../data/models/user_model.dart';
import '../../../data/network/mapbox_token_gate.dart';
import '../../../data/network/mapbox_token_service.dart';
import '../../calendar/calendar_events_provider.dart';
import '../../calendar/event_marker.dart';
import '../../checkpoints/checkpoint_editor_screen.dart';
import '../../checkpoints/checkpoints_provider.dart';
import '../local_avatar_store.dart';
import '../map_variant.dart';
import 'map_geometry.dart';
import '../map_settings.dart';
import 'map_layers.dart';
import 'map_contents_semantics.dart';
import 'map_viewers_row.dart';
import 'mapbox_map.dart';
import 'marker_icons.dart';
import 'tracking_map_layer.dart';
import 'tracking_users_drawer.dart';
import '../../../core/palette.dart';

/// Zoomed out further, checkpoint names would pile up into noise; circles stay.
const double _checkpointLabelsFromZoom = 13;

/// Screen-pixel distance under which two markers fold into one bubble. Sized
/// to the bubble's visual footprint, so two icons never overlap unnoticed.
const double _clusterPixelRadius = 96;

/// Real-world distance under which markers may be folded together. The pixel
/// limit alone shrinks in metres as the map zooms out, which would merge
/// people kilometres apart; this keeps a cluster meaning "actually together".
const double _clusterMaxMeters = 100;

class TrackingMapTab extends StatefulWidget {
  const TrackingMapTab({
    super.key,
    required this.isActive,
    required this.center,
    required this.centerIsKnown,
    required this.selectedLayer,
    required this.lightPreset,
    required this.peers,
    required this.selfProfile,
    required this.selfTrackingPaused,
    required this.selfMissingPermissions,
    required this.selfBatterySavingEnabled,
    required this.viewers,
    required this.selectedUserId,
    required this.onLayerSelected,
    required this.onUserSelected,
    required this.onSelectionCleared,
    this.mapboxTokenService,
  });

  final bool isActive;
  final LatLng center;

  /// Whether `center` is a real place - a live fix or the one cached from the
  /// last session - rather than the app's fallback. The map opens at the
  /// neighbourhood zoom only when it is.
  final bool centerIsKnown;
  final MapLayer selectedLayer;

  /// The basemap lighting, resolved by the screen from the picked map variant.
  final MapLightPreset lightPreset;
  final List<UserProfile> peers;
  final UserProfile selfProfile;
  final bool selfTrackingPaused;
  final bool selfMissingPermissions;
  final bool selfBatterySavingEnabled;

  /// Who has the live map open right now, us included.
  final List<MapViewer> viewers;
  final String? selectedUserId;
  final ValueChanged<MapLayer> onLayerSelected;
  final ValueChanged<UserProfile> onUserSelected;

  /// The drawer returned to the list: drop the selected marker and the camera
  /// that was following them.
  final VoidCallback onSelectionCleared;

  final MapboxTokenService? mapboxTokenService;

  @override
  State<TrackingMapTab> createState() => TrackingMapTabState();
}

class TrackingMapTabState extends State<TrackingMapTab>
    with TickerProviderStateMixin {
  final MarkerIconFactory _icons = MarkerIconFactory();
  final Map<String, MarkerImage> _images = {};

  /// The last rendered bitmap per marker slot, kept while the next one (a
  /// new speed bucket, battery level, avatar) renders asynchronously -
  /// without it a marker blinks out for a frame at every change.
  final Map<String, MarkerImage> _slotImages = {};
  final Set<String> _seenSlots = {};
  final Set<String> _pendingImages = {};

  /// Bumped whenever the icon factory rebuilds, so a render already in flight
  /// with the older bitmaps cannot write itself back into the cache.
  int _iconEpoch = 0;

  /// What the map draws. Marker positions change ~10x a second; rebuilding the
  /// drawer and the control column alongside them is what made the map
  /// stutter, so motion updates this scene and the map re-syncs on its own.
  final MapScene _scene = MapScene();

  /// Lets the back gesture reach the sheet's own collapse, which is a
  /// controller animation the props cannot express.
  final GlobalKey<TrackingUsersDrawerState> _drawerKey =
      GlobalKey<TrackingUsersDrawerState>();

  MapboxMap? _map;
  Size? _mapSize;
  double _cameraZoom = AppConstants.defaultZoom;
  late LatLng _cameraCenter;

  final Map<int, Offset> _pointerLocations = {};

  bool _autoFollow = false;
  bool _cameraAnimating = false;
  String? _followedUserId;
  int _selectionTick = 0;

  /// Fraction of the map's height the people sheet covers right now.
  double _sheetFraction = 0;

  /// The same fraction as a notifier, so the my-location button can ride on
  /// the sheet without rebuilding the map while it is dragged.
  final ValueNotifier<double> _sheetExtent = ValueNotifier(0);

  /// Whether the map is turned away from north, for the reset-north button.
  bool _turned = false;

  final Map<String, MarkerMotion> _motions = {};

  bool _didJumpToInitialFix = false;
  DateTime? _lastMotionBuild;
  DateTime? _lastClusterBuild;

  @override
  void initState() {
    super.initState();
    _cameraCenter = widget.center;
    // Open on ourselves (live fix or the one cached from last time) at the
    // neighbourhood zoom, not at the world-spanning default.
    if (widget.centerIsKnown) _cameraZoom = _startZoom;
    _icons.addListener(_handleIconsChanged);
    _syncMarkerMotions();
  }

  @override
  void didUpdateWidget(covariant TrackingMapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMarkerMotions();
    _jumpToInitialFixIfNeeded(oldWidget);
  }

  @override
  void dispose() {
    _icons
      ..removeListener(_handleIconsChanged)
      ..dispose();
    _scene.dispose();
    _sheetExtent.dispose();
    for (final motion in _motions.values) {
      motion.dispose();
    }
    _motions.clear();
    super.dispose();
  }

  void _handleIconsChanged() {
    if (!mounted) return;
    // An avatar finished loading: every cached icon keyed on "no photo yet"
    // has to be rebuilt with the photo.
    _images.clear();
    _pendingImages.clear();
    _iconEpoch++;
    _publishScene();
  }

  void _jumpToInitialFixIfNeeded(TrackingMapTab oldWidget) {
    if (_didJumpToInitialFix) return;
    if (oldWidget.center.latitude == widget.center.latitude &&
        oldWidget.center.longitude == widget.center.longitude) {
      return;
    }
    if (_pointerLocations.isNotEmpty) return;
    // The cached fix from the last session moves the camera too, but it does
    // not retire the jump: the first live fix from the engine still earns one.
    if (widget.selfProfile.lastLocation != null) _didJumpToInitialFix = true;
    _moveCamera(
      widget.center,
      _startZoom,
      animate: false,
      sheetFraction: _sheetFraction,
    );
  }

  void _syncMarkerMotions() {
    final activeIds = <String>{widget.selfProfile.id};
    _motionFor(widget.selfProfile.id).update(widget.selfProfile.lastLocation);
    for (final peer in widget.peers) {
      activeIds.add(peer.id);
      _motionFor(peer.id).update(peer.lastLocation);
    }
    final stale = _motions.keys.where((id) => !activeIds.contains(id)).toList();
    for (final id in stale) {
      _motions.remove(id)!.dispose();
    }
  }

  MarkerMotion _motionFor(String id) {
    return _motions.putIfAbsent(
      id,
      () => MarkerMotion(vsync: this, onTick: _handleMotionTick),
    );
  }

  /// The view the map opens with: roughly 15 km across a phone's width -
  /// far enough to see the neighbourhood, close enough to place yourself in
  /// it. Selecting someone still zooms to the street level of [_recenterZoom].
  double get _startZoom => 11.5;

  /// Street-level enough to recognise where you are, the zoom the "where am
  /// I" button and selecting a person aim for; the web focuses at ≥ 16.
  double get _recenterZoom =>
      math.min(AppConstants.maxZoom, AppConstants.defaultZoom + 3.5);

  double get _currentZoomForSelection =>
      math.min(AppConstants.maxZoom, math.max(_cameraZoom, _recenterZoom));

  double get _mapHeight =>
      _mapSize?.height ?? MediaQuery.sizeOf(context).height;

  void _moveCamera(
    LatLng target,
    double zoom, {
    bool animate = true,
    double sheetFraction = 0,
  }) {
    if (!target.latitude.isFinite || !target.longitude.isFinite) return;
    final clampedZoom = zoom
        .clamp(AppConstants.minZoom, AppConstants.maxZoom)
        .toDouble();
    // Keep the requested view even before the native map exists: the initial
    // fix can arrive while the first MapWidget is still being created.
    _cameraCenter = target;
    _cameraZoom = clampedZoom;
    final map = _map;
    if (map == null) return;
    final covered = coveredMapHeight(sheetFraction, _mapHeight);
    final camera = CameraOptions(
      center: Point(coordinates: Position(target.longitude, target.latitude)),
      zoom: clampedZoom,
      // Padding puts the target in the middle of the part of the map the
      // people sheet leaves visible, rather than behind it.
      padding: MbxEdgeInsets(top: 0, left: 0, bottom: covered, right: 0),
    );
    if (animate) {
      _cameraAnimating = true;
      map.easeTo(camera, MapAnimationOptions(duration: 300));
      Future<void>.delayed(const Duration(milliseconds: 320), () {
        if (mounted) _cameraAnimating = false;
      });
    } else {
      _cameraAnimating = false;
      map.setCamera(camera);
    }
  }

  void _animateMapTo(
    LatLng target, {
    double? zoomTarget,
    double sheetFraction = 0,
  }) {
    if (!target.latitude.isFinite || !target.longitude.isFinite) return;
    final targetZoom = zoomTarget ?? _cameraZoom;
    if (_cameraCenter == target &&
        targetZoom == _cameraZoom &&
        sheetFraction == 0) {
      return;
    }
    _moveCamera(
      target,
      targetZoom,
      animate: true,
      sheetFraction: sheetFraction,
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pointerLocations[event.pointer] = event.position;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_autoFollow) return;
    final origin = _pointerLocations[event.pointer];
    if (origin == null) return;
    // A tap also reports a pixel or two of jitter. Rebuilding the tab on that
    // lands in the middle of the gesture, so only a real drag stops the camera.
    if ((event.position - origin).distance < kTouchSlop) return;
    setState(() {
      _autoFollow = false;
      _followedUserId = null;
    });
  }

  void _handlePointerUp(PointerUpEvent event) {
    _pointerLocations.remove(event.pointer);
  }

  /// A cancelled gesture would otherwise leave a pointer recorded forever,
  /// and the follow camera would stop moving.
  void _handlePointerCancel(PointerCancelEvent event) {
    _pointerLocations.remove(event.pointer);
  }

  void _focusUser(UserProfile profile) {
    _selectionTick++;
    final location = profile.lastLocation;
    if (location == null ||
        !location.latitude.isFinite ||
        !location.longitude.isFinite) {
      widget.onUserSelected(profile);
      return;
    }
    widget.onUserSelected(profile);
    _follow(
      profile,
      location,
      // Selecting someone opens the sheet on their details.
      sheetFraction: TrackingUsersDrawer.expandedSize,
    );
  }

  /// Back to the list of everyone: the map stops framing the person whose
  /// detail pane just closed.
  void _clearSelection() {
    if (_autoFollow || _followedUserId != null) {
      setState(() {
        _autoFollow = false;
        _followedUserId = null;
      });
    }
    widget.onSelectionCleared();
  }

  /// The Android back gesture: drop the selection *and* fold the sheet back
  /// to its peek, so a back press never leaves the map covered. The header's
  /// own back button keeps the list open - that one means "show me everyone".
  void clearSelectionAndCollapse() {
    _clearSelection();
    _drawerKey.currentState?.collapse();
  }

  void _focusCluster(List<UserProfile> members) {
    if (members.length == 1) {
      _focusUser(members.first);
      return;
    }
    final points = <LatLng>[
      for (final member in members) ?_motions[member.id]?.value,
    ];
    if (points.length < 2) {
      _focusUser(members.first);
      return;
    }
    setState(() {
      _autoFollow = false;
      _followedUserId = null;
    });
    final map = _map;
    if (map == null) return;
    final covered = _coveredSheetHeight;
    unawaited(
      map
          .cameraForCoordinatesPadding(
            [for (final point in points) _point(point)],
            CameraOptions(),
            MbxEdgeInsets(top: 80, left: 60, bottom: 80 + covered, right: 60),
            null,
            null,
          )
          .then((camera) {
            final center = camera.center;
            final zoom = camera.zoom;
            if (center == null || zoom == null) return;
            _moveCamera(
              LatLng(
                center.coordinates.lat.toDouble(),
                center.coordinates.lng.toDouble(),
              ),
              zoom,
              animate: true,
            );
          }),
    );
  }

  /// Centers on ourselves without opening our details: the button means "where
  /// am I", not "show me my stats".
  void _recenterOnSelf() {
    final location = widget.selfProfile.lastLocation;
    if (location != null &&
        location.latitude.isFinite &&
        location.longitude.isFinite) {
      _follow(widget.selfProfile, location, sheetFraction: _sheetFraction);
    }
  }

  void _follow(
    UserProfile profile,
    LocationPoint location, {
    required double sheetFraction,
  }) {
    setState(() {
      _autoFollow = true;
      _followedUserId = profile.id;
    });
    // The camera aims at where the sheet is going, but the covered band - and
    // with it the Mapbox ornaments - keeps following what the drawer reports,
    // so a sheet that has not moved yet cannot push the logo up the screen.
    _animateMapTo(
      LatLng(location.latitude, location.longitude),
      zoomTarget: _currentZoomForSelection,
      sheetFraction: sheetFraction,
    );
  }

  void _handleMotionTick() {
    if (!mounted) return;
    final now = DateTime.now();
    final last = _lastMotionBuild;
    // Native annotation updates cross a platform channel; ~20 fps keeps the
    // glide smooth without flooding it.
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 50)) {
      return;
    }
    _lastMotionBuild = now;
    _publishScene();
    _syncMapCameraToFollowedUser();
  }

  void _syncMapCameraToFollowedUser() {
    if (!mounted || !widget.isActive) return;
    if (!_autoFollow) return;
    // Let a deliberate focus animation finish before the motion tick takes
    // over camera control.
    if (_cameraAnimating) return;
    // Never move the camera while the user is touching the map.
    if (_pointerLocations.isNotEmpty) return;
    final followedId =
        _followedUserId ?? widget.selectedUserId ?? widget.selfProfile.id;
    final pos = _motions[followedId]?.value;
    if (pos == null) return;
    _moveCamera(
      pos,
      _cameraZoom,
      animate: false,
      sheetFraction: _sheetFraction,
    );
  }

  void _onCameraChanged(CameraState state) {
    final turned = state.bearing.abs() > 0.5;
    if (turned != _turned) setState(() => _turned = turned);
    final zoom = state.zoom;
    final delta = (zoom - _cameraZoom).abs();
    final labelsBefore = _cameraZoom >= _checkpointLabelsFromZoom;
    _cameraZoom = zoom;
    _cameraCenter = LatLng(
      state.center.coordinates.lat.toDouble(),
      state.center.coordinates.lng.toDouble(),
    );
    final labelsAfter = zoom >= _checkpointLabelsFromZoom;
    // Clusters and checkpoint labels depend on zoom, so a zoom change
    // republishes the scene. The control icons do not, so the rest of the
    // screen stays put.
    if (labelsBefore != labelsAfter) {
      _publishScene();
      return;
    }
    if (delta < 0.12) return;
    final now = DateTime.now();
    final last = _lastClusterBuild;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastClusterBuild = now;
    _publishScene();
  }

  /// Read in [build]; the map widget is built from callbacks that have no
  /// context of their own.
  MapSettings? _settings;

  void _resetNorth() {
    _map?.easeTo(CameraOptions(bearing: 0), MapAnimationOptions(duration: 400));
  }

  void _showLayers({
    required CalendarEventsProvider? events,
    required CheckpointsProvider? checkpoints,
  }) {
    final settings = _settings;
    showMapLayersSheet(
      context,
      selectedLayer: widget.selectedLayer,
      onLayerSelected: widget.onLayerSelected,
      orientationLocked: settings?.orientationLocked ?? true,
      onOrientationLockChanged: (locked) =>
          settings?.setOrientationLocked(locked),
      view3d: settings?.view3d ?? false,
      onView3dChanged: (enabled) => settings?.setView3d(enabled),
      showEvents: events != null && events.available ? events.enabled : null,
      onShowEventsChanged: (_) => events?.toggle(),
      showCheckpoints: checkpoints?.showOnMap,
      onShowCheckpointsChanged: (_) => checkpoints?.toggleShowOnMap(),
    );
  }

  Widget _mapWidget(BuildContext context, MapboxTokenSession session) {
    return MapboxMapWidget(
      key: ValueKey('tracking-map-${session.generation}'),
      accessToken: session.token,
      initialCenter: _cameraCenter,
      initialZoom: _cameraZoom,
      style: widget.selectedLayer,
      lightPreset: widget.lightPreset,
      orientationLocked: _settings?.orientationLocked ?? true,
      view3d: _settings?.view3d ?? false,
      scene: _scene,
      onMarkerTap: _onMarkerTap,
      onCheckpointTap: _openCheckpoint,
      onCameraChanged: _onCameraChanged,
      onLoadError: (_) => session.recover(),
      onMapCreated: (map) {
        _map = map;
        // Restores the last view after a token-error recreation.
        _moveCamera(
          _cameraCenter,
          _cameraZoom,
          animate: false,
          sheetFraction: _sheetFraction,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final events = context.watch<CalendarEventsProvider?>();
    final checkpointsProvider = context.watch<CheckpointsProvider?>();
    final selfAvatarBytes = context.watch<LocalAvatarStore?>()?.bytes;
    final settings = _settings = context.watch<MapSettings?>();
    final orientationLocked = settings?.orientationLocked ?? true;

    // Provider changes flow through this build; marker motion publishes the
    // scene directly so it never rebuilds the drawer or the controls.
    _refreshScene(
      events: events,
      checkpointsProvider: checkpointsProvider,
      selfAvatarBytes: selfAvatarBytes,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _mapSize) {
          _mapSize = size;
          WidgetsBinding.instance.addPostFrameCallback((_) => _publishInset());
        }
        return Stack(
          children: [
            Listener(
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: MapboxTokenGate(
                service: widget.mapboxTokenService,
                devToken: const String.fromEnvironment('MAPBOX_TOKEN'),
                builder: (context, session) => _mapWidget(context, session),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              child: MapContentsSemantics(
                selfId: widget.selfProfile.id,
                people: [widget.selfProfile, ...widget.peers],
                onSelect: widget.onUserSelected,
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topInset + 28,
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AppPalette.scrimTop, AppPalette.transparent],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: topInset + 12,
              left: 16,
              child: MapViewersRow(
                viewers: widget.viewers,
                selfId: widget.selfProfile.id,
                selfAvatarBytes: selfAvatarBytes,
              ),
            ),
            Positioned(
              top: topInset + 12,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  MapControlGroup(
                    children: [
                      MapControlButton(
                        icon: Icons.layers_outlined,
                        tooltip: 'Layers',
                        onPressed: () => _showLayers(
                          events: events,
                          checkpoints: checkpointsProvider,
                        ),
                      ),
                    ],
                  ),
                  // Only when the map can be turned and no longer faces north.
                  if (!orientationLocked && _turned) ...[
                    const SizedBox(height: 12),
                    MapControlGroup(
                      children: [
                        MapControlButton(
                          icon: Icons.explore_outlined,
                          tooltip: 'Reset north',
                          onPressed: _resetNorth,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // Bottom left like Google Maps, riding on top of the people sheet
            // and clear of the Mapbox logo that sits just above it.
            ValueListenableBuilder<double>(
              valueListenable: _sheetExtent,
              builder: (context, _, _) {
                return Positioned(
                  left: 16,
                  bottom: _coveredSheetHeight + 48,
                  child: MapControlGroup(
                    children: [
                      MapControlButton(
                        icon:
                            _autoFollow &&
                                _followedUserId == widget.selfProfile.id
                            ? Icons.my_location
                            : Icons.location_searching,
                        tooltip: 'My location',
                        onPressed: _recenterOnSelf,
                      ),
                    ],
                  ),
                );
              },
            ),
            TrackingUsersDrawer(
              key: _drawerKey,
              selfProfile: widget.selfProfile,
              peers: widget.peers,
              selfTrackingPaused: widget.selfTrackingPaused,
              selfMissingPermissions: widget.selfMissingPermissions,
              selfBatterySavingEnabled: widget.selfBatterySavingEnabled,
              selectedUserId: widget.selectedUserId,
              selectionTick: _selectionTick,
              onUserSelected: _focusUser,
              onSelectionCleared: _clearSelection,
              onExtentChanged: (fraction) {
                final changed = fraction != _sheetFraction;
                _sheetFraction = fraction;
                if (!changed) return;
                _sheetExtent.value = fraction;
                _publishInset();
                if (_autoFollow) _syncMapCameraToFollowedUser();
              },
            ),
          ],
        );
      },
    );
  }

  /// Keeps the Mapbox logo and attribution above the sheet: Mapbox requires
  /// both to stay visible, and the collapsed drawer paints over the strip the
  /// SDK puts them in by default.
  void _publishInset() {
    final inset = _coveredSheetHeight;
    if (inset == _scene.bottomInset) return;
    _scene.bottomInset = inset;
    _scene.markChanged();
  }

  void _publishScene() {
    if (!mounted) return;
    _refreshScene(
      events: context.read<CalendarEventsProvider?>(),
      checkpointsProvider: context.read<CheckpointsProvider?>(),
      selfAvatarBytes: context.read<LocalAvatarStore?>()?.bytes,
    );
  }

  void _refreshScene({
    required CalendarEventsProvider? events,
    required CheckpointsProvider? checkpointsProvider,
    required Uint8List? selfAvatarBytes,
  }) {
    final markers = _buildMarkers(
      events: events,
      selfAvatarBytes: selfAvatarBytes,
    );
    final checkpoints = (checkpointsProvider?.showOnMap ?? true)
        ? checkpointsProvider?.checkpoints ?? const <Checkpoint>[]
        : const <Checkpoint>[];
    final showLabels = _cameraZoom >= _checkpointLabelsFromZoom;
    final overlays = [
      for (final checkpoint in checkpoints)
        MapCheckpointOverlay(
          id: checkpoint.id,
          center: checkpoint.center,
          radiusMeters: checkpoint.radiusM.toDouble(),
          color: Theme.of(context).colorScheme.primary,
        ),
    ];
    if (showLabels) {
      // The web's name pill: a dark label with a pin, under people and events.
      final accent = Theme.of(context).colorScheme.primary;
      for (final checkpoint in checkpoints) {
        final image = _imageFor(
          'label:${checkpoint.name}:${accent.toARGB32()}',
          () => _icons.checkpointLabel(checkpoint.name, accent: accent),
        );
        if (image == null) continue;
        markers.add(
          MapMarker(
            id: 'label-${checkpoint.id}',
            position: checkpoint.center,
            image: image,
            layer: MapMarkerLayer.label,
          ),
        );
      }
    }

    // Skip the notify when nothing moved: the drawer rebuilds for other
    // reasons, and re-syncing identical annotations is pure overhead.
    final inset = _coveredSheetHeight;
    if (_sameMarkers(_scene.markers, markers) &&
        _sameOverlays(_scene.checkpoints, overlays) &&
        inset == _scene.bottomInset) {
      return;
    }
    _scene
      ..markers = markers
      ..checkpoints = overlays
      ..bottomInset = inset
      ..markChanged();
  }

  /// The band of map the drawer paints over, which is where Mapbox insists its
  /// logo and attribution must not be. Clamped so the ornaments stay in view
  /// even with the sheet opened over the whole map, and 0 until the map has
  /// been laid out - never a guess from the screen height.
  double get _coveredSheetHeight {
    final height = _mapSize?.height;
    if (height == null || height <= 0) return 0;
    return coveredMapHeight(_sheetFraction, height).roundToDouble();
  }

  /// Self plus every peer with a fix, grouped into bubbles at the current
  /// zoom. Positions come from the glide animations, so markers move smoothly
  /// between fixes instead of teleporting.
  List<MapMarker> _buildMarkers({
    required CalendarEventsProvider? events,
    required Uint8List? selfAvatarBytes,
  }) {
    final entries = <ClusterInput<_TrackedUser>>[];
    void add(UserProfile profile, {required bool isSelf}) {
      final location = profile.lastLocation;
      if (location == null ||
          !location.latitude.isFinite ||
          !location.longitude.isFinite) {
        return;
      }
      entries.add(
        ClusterInput(
          value: _TrackedUser(profile, isSelf: isSelf),
          point: _animatedPoint(profile.id, location),
        ),
      );
    }

    add(widget.selfProfile, isSelf: true);
    for (final peer in widget.peers) {
      add(peer, isSelf: false);
    }

    final markers = <MapMarker>[];
    _seenSlots.clear();
    for (final group in clusterMarkers(
      entries,
      zoom: _cameraZoom,
      pixelRadius: _clusterPixelRadius,
      maxMeters: _clusterMaxMeters,
    )) {
      final persons = [
        for (final member in group.members)
          MarkerPerson(
            id: member.value.profile.id,
            name: member.value.profile.name,
            avatarUrl: member.value.profile.avatarUrl,
            avatarBytes: member.value.isSelf ? selfAvatarBytes : null,
            isStale: _isStale(member.value.profile),
            isSelected: widget.selectedUserId == member.value.profile.id,
            isSelf: member.value.isSelf,
            isMoving: member.value.profile.lastLocation?.isMoving ?? false,
            speedKmh: (member.value.profile.lastLocation?.speed ?? 0) * 3.6,
            batteryLevel: member.value.profile.batteryLevel,
            isCharging: member.value.profile.isCharging ?? false,
          ),
      ];
      final single = group.members.length == 1;
      final signature = [
        for (final person in persons)
          '${person.id}|${person.name}|${person.avatarUrl}|'
              '${identityHashCode(person.avatarBytes)}|'
              '${person.isStale}|${person.isSelf}|${person.isMoving}|'
              '${(person.speedKmh / 5).round() * 5}|${person.batteryLevel}|'
              '${person.isCharging}',
      ].join(',');
      final colors = _markerColors;
      final slotId = single
          ? 'user-${group.members.first.value.profile.id}'
          : 'cluster-${group.members.map((m) => m.value.profile.id).join('-')}';
      var image = _imageFor(
        single
            ? 'person:${colors.id}:$signature'
            : 'cluster:${_clusterStyle.id}:$signature',
        () => single
            ? _icons.personMarker(persons.first, colors: colors)
            : _icons.clusterMarker(persons, style: _clusterStyle),
      );
      // A new speed bucket or battery level re-renders asynchronously; keep
      // the slot's previous bitmap on screen until the new one lands, so the
      // marker never blinks out mid-motion.
      if (image != null) {
        _slotImages[slotId] = image;
      } else {
        image = _slotImages[slotId];
      }
      if (image == null) continue;
      _seenSlots.add(slotId);

      final member = group.members.first.value;
      final person = persons.first;
      final heading = member.profile.lastLocation?.heading;
      // The web scales the whole marker: selected 1.18, moving 1.08.
      final markerScale = single
          ? person.isSelected
                ? 1.18
                : person.isMoving
                ? 1.08
                : 1.0
          : 1.0;
      if (single && person.isMoving && heading != null && heading.isFinite) {
        // PeerMarker.vue's cone under anyone on the move; stale keeps its
        // offline grey, like the ring and the badges.
        final beam = _imageFor(
          'beam:${person.isStale ? 'stale' : colors.id}',
          () => _icons.headingBeam(
            person.isStale ? MarkerColors.staleRing : colors.accent,
          ),
        );
        if (beam != null) {
          markers.add(
            MapMarker(
              id: 'beam-${person.id}',
              position: group.members.first.point,
              image: beam,
              layer: MapMarkerLayer.beam,
              rotation: heading,
              iconSize: markerScale,
            ),
          );
        }
      }
      markers.add(
        MapMarker(
          id: slotId,
          position: single ? group.members.first.point : group.center,
          image: image,
          layer: single ? MapMarkerLayer.person : MapMarkerLayer.cluster,
          iconSize: markerScale,
          // The person bitmap is decoration: its 152x168 box is the beam's
          // footprint, and Mapbox hit-tests that whole box, so the payload
          // lives on a tight avatar-sized hit area instead (below). The
          // cluster bitmap keeps its payload: the bubble body is the
          // zoom-to-separate target.
          payload: single
              ? null
              : [for (final m in group.members) m.value.profile],
        ),
      );
      if (single) {
        final hit = _imageFor('person-hit', () => _icons.personHitArea());
        if (hit != null) {
          markers.add(
            MapMarker(
              id: 'user-hit-${member.profile.id}',
              position: group.members.first.point,
              image: hit,
              layer: MapMarkerLayer.user,
              iconSize: markerScale,
              payload: member.profile,
            ),
          );
        }
      }
      if (!single) {
        // A face inside the bubble selects that person, like on the web.
        // The tap callback names the annotation but never the touch point,
        // so each visible face gets a transparent hit area over the bitmap;
        // the bubble body keeps the zoom-to-separate tap. Right to left, so
        // the leftmost zone ends up on top where neighbours overlap - the
        // same stack order the web gives the faces.
        final hit = _imageFor(
          'cluster-face-hit',
          () => _icons.clusterFaceHitArea(),
        );
        if (hit != null) {
          final offsets = MarkerIconFactory.clusterFaceOffsets(persons.length);
          for (var i = offsets.length - 1; i >= 0; i--) {
            markers.add(
              MapMarker(
                id: 'cluster-face-${group.members[i].value.profile.id}',
                position: group.center,
                image: hit,
                layer: MapMarkerLayer.clusterFace,
                iconOffset: offsets[i],
                payload: group.members[i].value.profile,
              ),
            );
          }
        }
      }
    }

    if (events != null) {
      for (final event in events.visibleEvents) {
        final point = event.point;
        if (point == null || !point.latitude.isFinite) continue;
        final color = event.color ?? eventFallbackColor;
        final image = _imageFor(
          'event:${color.toARGB32()}',
          () => _icons.eventMarker(color),
        );
        if (image == null) continue;
        markers.add(
          MapMarker(
            id: 'event-${event.id}',
            position: point,
            image: image,
            layer: MapMarkerLayer.event,
            payload: event,
          ),
        );
      }
    }

    // Slots that no longer exist (people who left the map, clusters that
    // split) must not pin their last bitmap forever.
    _slotImages.removeWhere((id, _) => !_seenSlots.contains(id));
    return markers;
  }

  /// Marker ring/pill/accent colours from the current app theme, so the
  /// markers follow light, dark and dynamic Material You alike.
  MarkerColors get _markerColors =>
      MarkerColors.from(Theme.of(context).colorScheme);

  /// The bubble is the same colour as the avatar rings on the map (the peer
  /// pill colour), so a cluster reads as one object with the people list,
  /// not a second card style. The tail dot is the theme accent.
  ClusterStyle get _clusterStyle {
    final scheme = Theme.of(context).colorScheme;
    return ClusterStyle(
      bubble: scheme.surfaceContainerHighest,
      chip: scheme.brightness == Brightness.light
          ? AppPalette.chip
          : scheme.onSurface,
      chipText: scheme.brightness == Brightness.light
          ? AppPalette.white
          : scheme.surface,
      accent: scheme.primary,
    );
  }

  /// Greyed out when we haven't heard from the device in a while. Uses the
  /// server's last-seen time, not the position's age: a parked user's last
  /// point is old by design yet they are still online.
  bool _isStale(UserProfile profile) {
    if (profile.id == widget.selfProfile.id) return false;
    return profile.isStale;
  }

  void _onMarkerTap(MapMarker marker) {
    final payload = marker.payload;
    if (payload is UserProfile) {
      _focusUser(payload);
    } else if (payload is List<UserProfile>) {
      _focusCluster(payload);
    } else if (payload is CalendarEvent) {
      showEventDetails(context, payload);
    }
  }

  /// Tapping a checkpoint circle opens that checkpoint, the same way its row
  /// in the checkpoints list does.
  void _openCheckpoint(MapCheckpointOverlay overlay) {
    final provider = context.read<CheckpointsProvider?>();
    if (provider == null) return;
    Checkpoint? checkpoint;
    for (final candidate in provider.checkpoints) {
      if (candidate.id == overlay.id) {
        checkpoint = candidate;
        break;
      }
    }
    if (checkpoint == null) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CheckpointEditorScreen(
            checkpoint: checkpoint,
            mapLayer: widget.selectedLayer,
          ),
        ),
      ),
    );
  }

  MarkerImage? _imageFor(String key, Future<MarkerImage> Function() build) {
    final cached = _images[key];
    if (cached != null) return cached;
    if (_pendingImages.add(key)) {
      final epoch = _iconEpoch;
      unawaited(
        build()
            .then((image) {
              _pendingImages.remove(key);
              // The icon set was rebuilt (an avatar landed) while this render
              // was in flight, so its bitmap still shows the initial: caching
              // it here is how a photo stayed missing after it had loaded.
              if (!mounted || epoch != _iconEpoch) return;
              _images[key] = image;
              // Only the annotations need to know a finished icon exists.
              _publishScene();
            })
            .catchError((_) {
              _pendingImages.remove(key);
            }),
      );
    }
    return null;
  }

  LatLng _animatedPoint(String id, LocationPoint fallback) {
    return _motions[id]?.value ?? LatLng(fallback.latitude, fallback.longitude);
  }

  bool _sameMarkers(List<MapMarker> a, List<MapMarker> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.id != right.id ||
          left.layer != right.layer ||
          left.image.id != right.image.id ||
          left.iconSize != right.iconSize ||
          left.rotation != right.rotation ||
          left.iconOffset != right.iconOffset ||
          left.position.latitude != right.position.latitude ||
          left.position.longitude != right.position.longitude) {
        return false;
      }
    }
    return true;
  }

  bool _sameOverlays(
    List<MapCheckpointOverlay> a,
    List<MapCheckpointOverlay> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.id != right.id ||
          left.radiusMeters != right.radiusMeters ||
          left.color != right.color ||
          left.center.latitude != right.center.latitude ||
          left.center.longitude != right.center.longitude) {
        return false;
      }
    }
    return true;
  }

  Point _point(LatLng point) =>
      Point(coordinates: Position(point.longitude, point.latitude));
}

/// A trackable user (self or peer), used as the unit clustering groups
/// together.
class _TrackedUser {
  const _TrackedUser(this.profile, {required this.isSelf});

  final UserProfile profile;
  final bool isSelf;
}

@visibleForTesting
class MarkerMotion {
  MarkerMotion({required TickerProvider vsync, required this.onTick})
    : _controller = AnimationController(vsync: vsync) {
    _controller
      ..addListener(_handleTick)
      ..addStatusListener(_handleStatus);
  }

  // Glide bounds: long enough that movement reads as continuous, short enough
  // that a late update doesn't leave the marker crawling far behind reality.
  static const Duration _minGlide = Duration(milliseconds: 300);
  static const Duration _maxGlide = Duration(seconds: 4);
  static const Duration _defaultGlide = Duration(milliseconds: 1000);

  // Fixes rarely arrive on the beat, so a glide is timed from the average gap
  // and runs well past it: the marker is still moving when the next fix lands
  // instead of standing still waiting for it. The price is a marker that trails
  // reality by about a gap; a backlog is absorbed by the next glide.
  static const double _glideSlack = 1.5;

  // How much of each new gap goes into the running average.
  static const double _gapWeight = 0.3;

  // Past this long without a fix the marker is stale (the app was closed or
  // the user sat still), and a glide would drag it slowly across the map
  // instead of showing where they are now.
  static const Duration _staleAfter = Duration(seconds: 15);

  /// Overridable clock so tests can age the last update.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  final AnimationController _controller;
  final VoidCallback onTick;

  /// Route of the current glide: [_path] first is where it began, last is the
  /// newest fix. [_cumulative] holds the distance along it at each waypoint.
  List<LatLng> _path = const [];
  List<double> _cumulative = const [0];
  bool _gliding = false;
  LatLng? _displayed;
  LatLng? _lastTarget;
  DateTime? _lastUpdateAt;

  /// Running average of the gap between fixes, so one short gap doesn't end
  /// the next glide early.
  Duration? _gap;

  /// The position the marker should currently be drawn at, or null until a
  /// valid location has been seen.
  LatLng? get value => _displayed;

  /// Extends the route to [location] from wherever the marker is drawn now,
  /// through the waypoints it has not reached yet, and re-times the whole
  /// remainder to the average gap between updates: the marker never cuts a
  /// corner or stops between fixes. Movement is keyed on the coordinates
  /// rather than the timestamp: peer timestamps come from the server's
  /// `recorded_at`, which can repeat across updates, whereas a changed
  /// position is exactly what should trigger a glide.
  void update(LocationPoint? location) {
    if (location == null ||
        !location.latitude.isFinite ||
        !location.longitude.isFinite) {
      _controller.stop();
      _gliding = false;
      _path = const [];
      _displayed = null;
      _lastTarget = null;
      _lastUpdateAt = null;
      _gap = null;
      return;
    }

    final target = LatLng(location.latitude, location.longitude);
    if (_lastTarget != null && _sameLatLng(_lastTarget!, target)) {
      return;
    }

    final now = clock();
    final interval = _lastUpdateAt == null
        ? null
        : now.difference(_lastUpdateAt!);
    _lastUpdateAt = now;
    _lastTarget = target;
    if (interval != null && interval > _staleAfter) {
      _controller.stop();
      _gliding = false;
      _path = const [];
      _displayed = target;
      _gap = null;
      return;
    }
    if (interval != null) {
      final gap = _gap;
      _gap = gap == null ? interval : gap + (interval - gap) * _gapWeight;
    }

    final start = _displayed ?? target;
    if (_sameLatLng(start, target)) {
      _displayed = target;
      _gliding = false;
      return;
    }

    // Waypoints still ahead of the marker, so it carries on through them.
    final ahead = <LatLng>[];
    if (_gliding && _path.length > 1) {
      final along = _controller.value * _cumulative.last;
      ahead.addAll(_path.skip(_segmentAt(along) + 1));
      ahead.removeWhere((point) => _sameLatLng(point, start));
    }
    _controller.stop();
    _path = [start, ...ahead, target];
    _cumulative = [0];
    for (var i = 1; i < _path.length; i++) {
      _cumulative.add(_cumulative[i - 1] + _distance(_path[i - 1], _path[i]));
    }
    _gliding = true;
    _controller
      ..duration = _glideDuration(_gap)
      ..forward(from: 0);
  }

  /// Spreads the glide across the measured time between updates so the marker
  /// arrives roughly as the next fix lands, clamped to sane bounds.
  Duration _glideDuration(Duration? interval) {
    if (interval == null) return _defaultGlide;
    final slackened = interval * _glideSlack;
    if (slackened < _minGlide) return _minGlide;
    if (slackened > _maxGlide) return _maxGlide;
    return slackened;
  }

  /// Index of the route segment containing distance [along].
  int _segmentAt(double along) {
    var i = 0;
    while (i < _path.length - 2 && _cumulative[i + 1] <= along) {
      i++;
    }
    return i;
  }

  /// Ground distance in degrees of latitude: longitude shrinks with the
  /// cosine of latitude.
  static double _distance(LatLng a, LatLng b) {
    final scale = math.cos((a.latitude + b.latitude) / 2 * math.pi / 180);
    return math.sqrt(
      math.pow(b.latitude - a.latitude, 2) +
          math.pow((b.longitude - a.longitude) * scale, 2),
    );
  }

  void _handleTick() {
    if (!_gliding || _path.length < 2) return;
    final total = _cumulative.last;
    final along = _controller.value * total;
    final i = _segmentAt(along);
    final span = _cumulative[i + 1] - _cumulative[i];
    final f = span > 0 ? (along - _cumulative[i]) / span : 1.0;
    final from = _path[i];
    final to = _path[i + 1];
    _displayed = LatLng(
      from.latitude + (to.latitude - from.latitude) * f,
      from.longitude + (to.longitude - from.longitude) * f,
    );
    onTick();
  }

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_path.isNotEmpty) _displayed = _path.last;
    _gliding = false;
  }

  void dispose() {
    _controller
      ..removeListener(_handleTick)
      ..removeStatusListener(_handleStatus)
      ..dispose();
  }

  static bool _sameLatLng(LatLng a, LatLng b) =>
      a.latitude == b.latitude && a.longitude == b.longitude;
}
