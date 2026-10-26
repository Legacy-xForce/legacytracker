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
  final bool selfLive;
  final List<MapViewer> viewers;
  final String? selectedUserId;
  final ValueChanged<MapLayer> onLayerSelected;
  final ValueChanged<UserProfile> onUserSelected;
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
    _icons
      ..removeListener(_handleIconsChanged)
      ..dispose();
    for (final motion in _motions.values) {
      motion.dispose();
    }
    _motions.clear();
    super.dispose();
  }

  void _handleIconsChanged() {
    if (!mounted) return;
    setState(() => _images.clear());
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
    final covered = (sheetFraction * _mapHeight)
        .clamp(0.0, _mapHeight)
        .toDouble();
    final camera = CameraOptions(
      center: Point(coordinates: Position(target.longitude, target.latitude)),
      zoom: clampedZoom,
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
    final covered = _sheetFraction * _mapHeight;
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
    _animateMapTo(
      LatLng(location.latitude, location.longitude),
      zoomTarget: _currentZoomForSelection,
      sheetFraction: sheetFraction,
    );
    _sheetFraction = sheetFraction;
  }

  void _handleMotionTick() {
    if (!mounted) return;
    final now = DateTime.now();
    final last = _lastMotionBuild;
    // Native annotation updates cross a platform channel; ~12 fps keeps the
    // glide smooth without flooding it.
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 80)) {
      return;
    }
    _lastMotionBuild = now;
    setState(() {});
    _syncMapCameraToFollowedUser();
  }

  void _syncMapCameraToFollowedUser() {
    if (!mounted || !widget.isActive) return;
    if (!_autoFollow) return;
    // Let a deliberate focus animation finish before the motion tick takes
    // over camera control.
    if (_cameraAnimating) return;
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
    // Crossing the label threshold must rebuild even if the zoom change was
    // small; otherwise a slow pinch can stop just short of updating them.
    if (labelsBefore != labelsAfter) {
      setState(() {});
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
    setState(() {});
  }

  MapboxMapWidget _mapWidget(
    BuildContext context,
    MapboxTokenSession session,
    List<MapMarker> markers,
    List<MapCheckpointOverlay> checkpoints,
  ) {
    return MapboxMapWidget(
      key: ValueKey('tracking-map-${session.generation}'),
      accessToken: session.token,
      initialCenter: _cameraCenter,
      initialZoom: _cameraZoom,
      style: widget.selectedLayer,
      darkMode: Theme.of(context).brightness == Brightness.dark,
      markers: markers,
      checkpoints: checkpoints,
      showCheckpointLabels: true,
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
    final checkpoints = (checkpointsProvider?.showOnMap ?? true)
        ? checkpointsProvider?.checkpoints ?? const <Checkpoint>[]
        : const <Checkpoint>[];
    final selfAvatarBytes = context.watch<LocalAvatarStore?>()?.bytes;

    final markers = _buildMarkers(
      context,
      events: events,
      selfAvatarBytes: selfAvatarBytes,
    );
    final checkpointOverlays = <MapCheckpointOverlay>[
      for (final checkpoint in checkpoints)
        MapCheckpointOverlay(
          id: checkpoint.id,
          center: checkpoint.center,
          radiusMeters: checkpoint.radiusM.toDouble(),
          label: _cameraZoom >= _checkpointLabelsFromZoom
              ? checkpoint.name
              : null,
        ),
    ];

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
                builder: (context, session) =>
                    _mapWidget(context, session, markers, checkpointOverlays),
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
                if (changed && _autoFollow) _syncMapCameraToFollowedUser();
              },
            ),
          ],
        );
      },
    );
  }

  List<MapMarker> _buildMarkers(
    BuildContext context, {
    required CalendarEventsProvider? events,
    required Uint8List? selfAvatarBytes,
  }) {
    final markers = <MapMarker>[];

    final entries = <ClusterInput<_TrackedUser>>[];
    final selfLocation = widget.selfProfile.lastLocation;
    if (_validLocation(selfLocation)) {
      entries.add(
        ClusterInput(
          value: _TrackedUser(widget.selfProfile, isSelf: true),
          point: _animatedPoint(widget.selfProfile.id, selfLocation!),
        ),
      );
    }
    for (final peer in widget.peers) {
      final location = peer.lastLocation;
      if (!_validLocation(location)) continue;
      entries.add(
        ClusterInput(
          value: _TrackedUser(peer, isSelf: false),
          point: _animatedPoint(peer.id, location!),
        ),
      );
    }

    final groups = clusterMarkers(
      entries,
      zoom: _cameraZoom,
      pixelRadius: 96,
      maxMeters: 100,
    );
    for (final group in groups) {
      final persons = <MarkerPerson>[
        for (final member in group.members)
          MarkerPerson(
            id: member.value.profile.id,
            name: member.value.profile.name,
            avatarUrl: member.value.profile.avatarUrl,
            avatarBytes: member.value.isSelf ? selfAvatarBytes : null,
            isStale: _isStale(member.value.profile),
            isSelected: widget.selectedUserId == member.value.profile.id,
          ),
      ];
      final signature = [
        for (final person in persons)
          '${person.id}|${person.name}|${person.avatarUrl}|'
              '${identityHashCode(person.avatarBytes)}|'
              '${person.isStale}|${person.isSelected}',
      ].join(',');
      final image = _imageFor(
        'live:$signature',
        () => _icons.liveMarker(persons),
      );
      if (image == null) continue;

      final single = group.members.length == 1;
      final member = group.members.first.value;
      markers.add(
        MapMarker(
          id: single
              ? 'user-${member.profile.id}'
              : 'cluster-${group.members.map((m) => m.value.profile.id).join('-')}',
          position: single ? group.members.first.point : group.center,
          image: image,
          layer: single ? MapMarkerLayer.user : MapMarkerLayer.cluster,
          payload: single
              ? member.profile
              : [for (final m in group.members) m.value.profile],
        ),
      );
    }

    if (events != null) {
      for (final event in events.visibleEvents) {
        final point = event.point;
        if (point == null) continue;
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
      unawaited(
        build()
            .then((image) {
              _pendingImages.remove(key);
              if (!mounted) return;
              setState(() => _images[key] = image);
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

  bool _validLocation(LocationPoint? location) =>
      location != null &&
      location.latitude.isFinite &&
      location.longitude.isFinite;

  bool _isStale(UserProfile profile) {
    if (profile.id == widget.selfProfile.id) return false;
    return profile.isStale;
  }

  Point _point(LatLng point) =>
      Point(coordinates: Position(point.longitude, point.latitude));
}

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

  static const Duration _minGlide = Duration(milliseconds: 300);
  static const Duration _maxGlide = Duration(seconds: 4);
  static const Duration _defaultGlide = Duration(milliseconds: 1000);

  final AnimationController _controller;
  final VoidCallback onTick;

  Animation<LatLng>? _animation;
  LatLng? _displayed;
  LatLng? _lastTarget;
  DateTime? _lastUpdateAt;

  LatLng? get value => _displayed;

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

  Duration _glideDuration(Duration? interval) {
    if (interval == null) {
      return _defaultGlide;
    }
    if (interval < _minGlide) return _minGlide;
    if (interval > _maxGlide) return _maxGlide;
    return interval;
  }

  void _handleTick() {
    final animated = _animation?.value;
    if (animated == null) {
      return;
    }
    _displayed = animated;
    onTick();
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      if (_animation != null) {
        _displayed = _animation!.value;
      }
      _animation = null;
    }
  }

  void dispose() {
    _controller
      ..removeListener(_handleTick)
      ..removeStatusListener(_handleStatus)
      ..dispose();
  }

  static bool _sameLatLng(LatLng a, LatLng b) {
    return a.latitude == b.latitude && a.longitude == b.longitude;
  }
}

class _LatLngTween extends Tween<LatLng> {
  _LatLngTween({required LatLng begin, required LatLng end})
    : super(begin: begin, end: end);

  @override
  LatLng lerp(double t) {
    return LatLng(
      begin!.latitude + (end!.latitude - begin!.latitude) * t,
      begin!.longitude + (end!.longitude - begin!.longitude) * t,
    );
  }
}

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
