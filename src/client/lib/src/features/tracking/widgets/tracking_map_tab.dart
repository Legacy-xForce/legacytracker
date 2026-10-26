import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

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
import '../../checkpoints/checkpoints_provider.dart';
import '../local_avatar_store.dart';
import 'map_geometry.dart';
import 'map_layers.dart';
import 'map_viewers_row.dart';
import 'mapbox_map.dart';
import 'marker_icons.dart';
import 'tracking_map_layer.dart';
import 'tracking_users_drawer.dart';

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
    required this.selectedLayer,
    required this.peers,
    required this.selfProfile,
    required this.selfTrackingPaused,
    required this.selfMissingPermissions,
    required this.selfBatterySavingEnabled,
    required this.selfLive,
    required this.viewers,
    required this.selectedUserId,
    required this.onLayerSelected,
    required this.onUserSelected,
    required this.onStatusTap,
    this.mapboxTokenService,
  });

  final bool isActive;
  final LatLng center;
  final MapLayer selectedLayer;
  final List<UserProfile> peers;
  final UserProfile selfProfile;
  final bool selfTrackingPaused;
  final bool selfMissingPermissions;
  final bool selfBatterySavingEnabled;

  /// Someone is watching the map, so devices are streaming in realtime.
  final bool selfLive;

  /// Who has the live map open right now, us included.
  final List<MapViewer> viewers;
  final String? selectedUserId;
  final ValueChanged<MapLayer> onLayerSelected;
  final ValueChanged<UserProfile> onUserSelected;

  /// The sharing-status pill was tapped (opens the sharing settings).
  final VoidCallback onStatusTap;
  final MapboxTokenService? mapboxTokenService;

  @override
  State<TrackingMapTab> createState() => _TrackingMapTabState();
}

class _TrackingMapTabState extends State<TrackingMapTab>
    with TickerProviderStateMixin {
  final MarkerIconFactory _icons = MarkerIconFactory();
  final Map<String, MarkerImage> _images = {};
  final Set<String> _pendingImages = {};

  /// Bumped whenever the icon factory rebuilds, so a render already in flight
  /// with the older bitmaps cannot write itself back into the cache.
  int _iconEpoch = 0;

  /// The web's pulse breathes once every 1.2s; 16 steps at 150ms give that
  /// without a frame-by-frame rebuild.
  Timer? _pulseTimer;
  int _pulseStep = 0;

  /// What the map draws. Marker positions change ~10x a second; rebuilding the
  /// drawer and the control column alongside them is what made the map
  /// stutter, so motion updates this scene and the map re-syncs on its own.
  final MapScene _scene = MapScene();

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

  final Map<String, _MarkerMotion> _motions = {};

  bool _didJumpToInitialFix = false;
  DateTime? _lastMotionBuild;
  DateTime? _lastClusterBuild;

  @override
  void initState() {
    super.initState();
    _cameraCenter = widget.center;
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
    _pulseTimer?.cancel();
    _icons
      ..removeListener(_handleIconsChanged)
      ..dispose();
    _scene.dispose();
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
    _didJumpToInitialFix = true;
    _moveCamera(
      widget.center,
      _cameraZoom,
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

  _MarkerMotion _motionFor(String id) {
    return _motions.putIfAbsent(
      id,
      () => _MarkerMotion(vsync: this, onTick: _handleMotionTick),
    );
  }

  double get _currentZoomForSelection => math.min(
    AppConstants.maxZoom,
    math.max(_cameraZoom, AppConstants.defaultZoom + 3.5),
  );

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
    _pointerLocations[event.pointer] = event.position;
    if (_autoFollow) {
      setState(() {
        _autoFollow = false;
        _followedUserId = null;
      });
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
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
    _sheetFraction = sheetFraction;
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
    // Native annotation updates cross a platform channel; ~10 fps keeps the
    // glide smooth without flooding it.
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 100)) {
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

  Widget _mapWidget(BuildContext context, MapboxTokenSession session) {
    return MapboxMapWidget(
      key: ValueKey('tracking-map-${session.generation}'),
      accessToken: session.token,
      initialCenter: _cameraCenter,
      initialZoom: _cameraZoom,
      style: widget.selectedLayer,
      darkMode: Theme.of(context).brightness == Brightness.dark,
      scene: _scene,
      onMarkerTap: _onMarkerTap,
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

    // Provider changes flow through this build; marker motion publishes the
    // scene directly so it never rebuilds the drawer or the controls.
    _refreshScene(
      events: events,
      checkpointsProvider: checkpointsProvider,
      selfAvatarBytes: selfAvatarBytes,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        _mapSize = constraints.biggest;
        return Stack(
          children: [
            Listener(
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              child: MapboxTokenGate(
                service: widget.mapboxTokenService,
                devToken: const String.fromEnvironment('MAPBOX_TOKEN'),
                builder: (context, session) => _mapWidget(context, session),
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
                      colors: [Color(0x99000000), Color(0x00000000)],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: topInset + 12,
              left: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SharingStatusPill(
                    paused: widget.selfTrackingPaused,
                    missingPermissions: widget.selfMissingPermissions,
                    live: widget.selfLive,
                    onTap: widget.onStatusTap,
                  ),
                  MapViewersRow(
                    viewers: widget.viewers,
                    selfId: widget.selfProfile.id,
                    selfAvatarBytes: selfAvatarBytes,
                  ),
                ],
              ),
            ),
            Positioned(
              top: topInset + 12,
              right: 16,
              child: MapControlGroup(
                children: [
                  MapLayerButton(
                    selectedLayer: widget.selectedLayer,
                    onLayerSelected: widget.onLayerSelected,
                  ),
                  MapControlButton(
                    icon:
                        _autoFollow && _followedUserId == widget.selfProfile.id
                        ? Icons.my_location
                        : Icons.location_searching,
                    tooltip: 'My location',
                    onPressed: _recenterOnSelf,
                  ),
                  if (events != null && events.available)
                    MapControlButton(
                      icon: events.enabled
                          ? Icons.event_rounded
                          : Icons.event_busy_outlined,
                      tooltip: events.enabled ? 'Hide events' : 'Show events',
                      color: events.enabled
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      onPressed: events.toggle,
                    ),
                  if (checkpointsProvider != null)
                    MapControlButton(
                      icon: checkpointsProvider.showOnMap
                          ? Icons.place_rounded
                          : Icons.location_off_outlined,
                      tooltip: checkpointsProvider.showOnMap
                          ? 'Hide checkpoints'
                          : 'Show checkpoints',
                      color: checkpointsProvider.showOnMap
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      onPressed: checkpointsProvider.toggleShowOnMap,
                    ),
                ],
              ),
            ),
            TrackingUsersDrawer(
              selfProfile: widget.selfProfile,
              peers: widget.peers,
              selfTrackingPaused: widget.selfTrackingPaused,
              selfMissingPermissions: widget.selfMissingPermissions,
              selfBatterySavingEnabled: widget.selfBatterySavingEnabled,
              selectedUserId: widget.selectedUserId,
              selectionTick: _selectionTick,
              onUserSelected: _focusUser,
              onExtentChanged: (fraction) {
                final changed = fraction != _sheetFraction;
                _sheetFraction = fraction;
                if (!changed) return;
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

  /// 0.725 → 1 → 0.725, matching PeerMarker.vue's keyframes.
  double get _pulseScale {
    final step = _pulseStep <= 7 ? _pulseStep : 15 - _pulseStep;
    return 0.725 + 0.275 * (step / 7);
  }

  void _syncPulseTimer(bool moving) {
    if (!moving) {
      _pulseTimer?.cancel();
      _pulseTimer = null;
      if (_pulseStep != 0) _pulseStep = 0;
      return;
    }
    _pulseTimer ??= Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted) return;
      _pulseStep = (_pulseStep + 1) % 16;
      _publishScene();
    });
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

    _syncPulseTimer(markers.any((m) => m.layer == MapMarkerLayer.pulse));

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
  /// even with the sheet opened over the whole map.
  double get _coveredSheetHeight =>
      coveredMapHeight(_sheetFraction, _mapHeight).roundToDouble();

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
              '${(person.speedKmh / 5).round()}|${person.batteryLevel}|'
              '${person.isCharging}',
      ].join(',');
      final image = _imageFor(
        '${single ? 'person' : 'cluster'}:$signature',
        () => single
            ? _icons.personMarker(persons.first)
            : _icons.clusterMarker(persons),
      );
      if (image == null) continue;

      final member = group.members.first.value;
      final person = persons.first;
      if (single && person.isMoving) {
        final pulse = _imageFor(
          'pulse:${person.isStale ? 'stale' : 'live'}',
          () => _icons.pulseMarker(
            person.isStale ? const Color(0xFF9E9E9E) : markerAccentColor,
          ),
        );
        if (pulse != null) {
          markers.add(
            MapMarker(
              id: 'pulse-${person.id}',
              position: group.members.first.point,
              image: pulse,
              layer: MapMarkerLayer.pulse,
              // The web scales the whole marker, pulse included.
              iconSize: _pulseScale * (person.isSelected ? 1.18 : 1.08),
            ),
          );
        }
      }
      markers.add(
        MapMarker(
          id: single
              ? 'user-${member.profile.id}'
              : 'cluster-${group.members.map((m) => m.value.profile.id).join('-')}',
          position: single ? group.members.first.point : group.center,
          image: image,
          layer: single ? MapMarkerLayer.user : MapMarkerLayer.cluster,
          // The web scales the whole marker: selected 1.18, moving 1.08.
          iconSize: single
              ? person.isSelected
                    ? 1.18
                    : person.isMoving
                    ? 1.08
                    : 1
              : 1,
          payload: single
              ? member.profile
              : [for (final m in group.members) m.value.profile],
        ),
      );
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

    return markers;
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

class _MarkerMotion {
  _MarkerMotion({required TickerProvider vsync, required this.onTick})
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

  final AnimationController _controller;
  final VoidCallback onTick;

  Animation<LatLng>? _animation;
  LatLng? _displayed;
  LatLng? _lastTarget;
  DateTime? _lastUpdateAt;

  /// The position the marker should currently be drawn at, or null until a
  /// valid location has been seen.
  LatLng? get value => _displayed;

  /// Tweens towards [location], reusing the previous position as the start
  /// point so the marker glides rather than teleports. Movement is keyed on
  /// the coordinates rather than the timestamp: peer timestamps come from the
  /// server's `recorded_at`, which can repeat across updates, whereas a
  /// changed position is exactly what should trigger a glide.
  void update(LocationPoint? location) {
    if (location == null ||
        !location.latitude.isFinite ||
        !location.longitude.isFinite) {
      _controller.stop();
      _animation = null;
      _displayed = null;
      _lastTarget = null;
      _lastUpdateAt = null;
      return;
    }

    final target = LatLng(location.latitude, location.longitude);
    if (_lastTarget != null && _sameLatLng(_lastTarget!, target)) {
      return;
    }

    final now = DateTime.now();
    final interval = _lastUpdateAt == null
        ? null
        : now.difference(_lastUpdateAt!);
    _lastUpdateAt = now;
    _lastTarget = target;

    final start = _displayed ?? target;
    if (_sameLatLng(start, target)) {
      _displayed = target;
      return;
    }

    _controller.stop();
    _animation = _LatLngTween(begin: start, end: target).animate(
      // Linear: constant-speed travel between fixes, so chained segments don't
      // ease-in/out and stutter at every waypoint.
      CurvedAnimation(parent: _controller, curve: Curves.linear),
    );
    _controller
      ..duration = _glideDuration(interval)
      ..forward(from: 0);
  }

  /// Spreads the glide across the measured time between updates so the marker
  /// arrives roughly as the next fix lands, clamped to sane bounds.
  Duration _glideDuration(Duration? interval) {
    if (interval == null) return _defaultGlide;
    if (interval < _minGlide) return _minGlide;
    if (interval > _maxGlide) return _maxGlide;
    return interval;
  }

  void _handleTick() {
    final animated = _animation?.value;
    if (animated == null) return;
    _displayed = animated;
    onTick();
  }

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_animation != null) _displayed = _animation!.value;
    _animation = null;
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

class _LatLngTween extends Tween<LatLng> {
  _LatLngTween({required LatLng begin, required LatLng end})
    : super(begin: begin, end: end);

  @override
  LatLng lerp(double t) => LatLng(
    begin!.latitude + (end!.latitude - begin!.latitude) * t,
    begin!.longitude + (end!.longitude - begin!.longitude) * t,
  );
}

/// Whether we're sharing our location, at a glance; tapping it opens the
/// sharing settings.
class _SharingStatusPill extends StatelessWidget {
  const _SharingStatusPill({
    required this.paused,
    required this.missingPermissions,
    required this.live,
    required this.onTap,
  });

  final bool paused;
  final bool missingPermissions;
  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, label) = missingPermissions
        ? (theme.colorScheme.error, 'Location off')
        : paused
        ? (Colors.amber, 'Sharing paused')
        : (const Color(0xFF34C759), live ? 'Sharing · live' : 'Sharing');

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 4,
      shadowColor: Colors.black54,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.6),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
