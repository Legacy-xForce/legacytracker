import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/constants.dart';
import '../../../data/models/checkpoint.dart';
import '../../../data/models/location_model.dart';
import '../../../data/models/map_viewer.dart';
import '../../../data/models/user_model.dart';
import '../../../data/network/mapbox_token_service.dart';
import '../../calendar/calendar_events_provider.dart';
import '../../checkpoints/checkpoints_provider.dart';
import 'map_layers.dart';
import 'map_viewers_row.dart';
import 'mapbox_map.dart';
import 'tracking_map_layer.dart';
import 'tracking_users_drawer.dart';
import '../local_avatar_store.dart';

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
  MapboxMap? _map;
  double _currentZoom = AppConstants.defaultZoom;
  LatLng _currentCenter = AppConstants.defaultMapCenter;

  int _mapKey = 0;
  String? _token;
  Timer? _tokenTimer;

  final Map<int, Offset> _pointerLocations = {};
  double? _lastRotationAngle;
  bool _isRotationLocked = true;
  static const double _rotationThreshold = 15.0;

  bool _autoFollow = false;
  String? _followedUserId;
  int _selectionTick = 0;

  double _sheetFraction = 0;

  final Map<String, _MarkerMotion> _motions = {};

  bool _didJumpToInitialFix = false;

  @override
  void initState() {
    super.initState();
    _syncMarkerMotions();
    _refreshToken();
    _tokenTimer = Timer.periodic(const Duration(minutes: 1), (_) => _refreshToken());
  }

  Future<void> _refreshToken() async {
    String? token;
    if (widget.mapboxTokenService != null) {
      token = await widget.mapboxTokenService!.token;
    } else {
      const devToken = String.fromEnvironment('MAPBOX_TOKEN', defaultValue: '');
      token = devToken.isEmpty ? null : devToken;
    }
    if (!mounted) return;
    if (token != _token) {
      setState(() {
        _token = token;
        _mapKey++;
      });
    }
  }

  @override
  void didUpdateWidget(covariant TrackingMapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMarkerMotions();
    _jumpToInitialFixIfNeeded(oldWidget);
  }

  void _jumpToInitialFixIfNeeded(TrackingMapTab oldWidget) {
    if (_didJumpToInitialFix) return;
    if (oldWidget.center.latitude == widget.center.latitude &&
        oldWidget.center.longitude == widget.center.longitude) {
      return;
    }
    if (_pointerLocations.isNotEmpty) return;
    _didJumpToInitialFix = true;
    _moveCamera(widget.center, _currentZoom, animate: false);
  }

  @override
  void dispose() {
    _tokenTimer?.cancel();
    for (final motion in _motions.values) {
      motion.dispose();
    }
    _motions.clear();
    super.dispose();
  }

  double get _currentZoomForSelection => math.min(
        AppConstants.maxZoom,
        math.max(_currentZoom, AppConstants.defaultZoom + 3.5),
      );

  void _moveCamera(LatLng target, double zoom, {bool animate = true}) {
    final map = _map;
    if (map == null) return;
    if (!target.latitude.isFinite || !target.longitude.isFinite) return;
    final camera = CameraOptions(
      center: Point(coordinates: Position(target.longitude, target.latitude)),
      zoom: zoom,
    );
    if (animate) {
      map.easeTo(camera, MapAnimationOptions(duration: 300));
    } else {
      map.setCamera(camera);
    }
    _currentCenter = target;
    _currentZoom = zoom;
  }

  void _animateMapTo(LatLng target, {double? zoomTarget}) {
    if (!target.latitude.isFinite || !target.longitude.isFinite) return;
    final targetZoom = zoomTarget ?? _currentZoom;
    if (_currentCenter == target && targetZoom == _currentZoom) return;
    _moveCamera(target, targetZoom, animate: true);
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pointerLocations[event.pointer] = event.position;
    _isRotationLocked = true;
    _lastRotationAngle = null;
    _map?.setCamera(CameraOptions(
      center: Point(coordinates: Position(_currentCenter.longitude, _currentCenter.latitude)),
      zoom: _currentZoom,
    ));
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _pointerLocations[event.pointer] = event.position;
    if (_pointerLocations.length >= 2) {
      final positions = _pointerLocations.values.toList();
      if (positions.length >= 2) {
        final angle = _calculateRotationAngle(positions[0], positions[1]);
        if (_lastRotationAngle != null) {
          final angleDelta = (angle - _lastRotationAngle!).abs();
          final normalizedDelta = angleDelta > 180 ? 360 - angleDelta : angleDelta;
          if (normalizedDelta > _rotationThreshold && _isRotationLocked) {
            _isRotationLocked = false;
          }
        }
        _lastRotationAngle = angle;
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _pointerLocations.remove(event.pointer);
    if (_pointerLocations.isEmpty) {
      _isRotationLocked = true;
      _lastRotationAngle = null;
    }
  }

  double _calculateRotationAngle(Offset p1, Offset p2) {
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    return math.atan2(dy, dx) * 180 / math.pi;
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
    _follow(profile, location, sheetFraction: TrackingUsersDrawer.expandedSize);
  }

  void _recenterOnSelf() {
    final location = widget.selfProfile.lastLocation;
    if (location != null &&
        location.latitude.isFinite &&
        location.longitude.isFinite) {
      _follow(widget.selfProfile, location, sheetFraction: _sheetFraction);
    }
    _animateBearingToNorth();
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
    final zoom = _currentZoomForSelection;
    _animateMapTo(LatLng(location.latitude, location.longitude), zoomTarget: zoom);
  }

  void _animateBearingToNorth() {
    _moveCamera(_currentCenter, _currentZoom, animate: true);
  }

  void _handleMotionTick() {
    if (!mounted) return;
    setState(() {});
    _syncMapCameraToFollowedUser();
  }

  void _syncMapCameraToFollowedUser() {
    if (!mounted || !widget.isActive) return;
    if (!_autoFollow) return;
    if (_pointerLocations.isNotEmpty) return;
    final followedId =
        _followedUserId ?? widget.selectedUserId ?? widget.selfProfile.id;
    final pos = _motions[followedId]?.value;
    if (pos == null) return;
    _moveCamera(LatLng(pos.latitude, pos.longitude), _currentZoom);
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final events = context.watch<CalendarEventsProvider?>();
    final checkpointsProvider = context.watch<CheckpointsProvider?>();
    final checkpoints = (checkpointsProvider?.showOnMap ?? true)
        ? checkpointsProvider?.checkpoints ?? const <Checkpoint>[]
        : const <Checkpoint>[];

    final mapPoints = <MapPoint>[];
    final selfLocation = widget.selfProfile.lastLocation;
    if (selfLocation != null &&
        selfLocation.latitude.isFinite &&
        selfLocation.longitude.isFinite) {
      mapPoints.add(MapPoint(
        id: widget.selfProfile.id,
        position: LatLng(selfLocation.latitude, selfLocation.longitude),
        label: widget.selfProfile.name,
        isSelf: true,
      ));
    }
    for (final peer in widget.peers) {
      final location = peer.lastLocation;
      if (location == null ||
          !location.latitude.isFinite ||
          !location.longitude.isFinite) {
        continue;
      }
      mapPoints.add(MapPoint(
        id: peer.id,
        position: LatLng(location.latitude, location.longitude),
        label: peer.name,
      ));
    }
    if (events != null && events.visibleEvents.isNotEmpty) {
      for (final event in events.visibleEvents) {
        if (event.point != null) {
          mapPoints.add(MapPoint(
            id: 'event-${event.id}',
            position: LatLng(event.point!.latitude, event.point!.longitude),
            label: event.title,
          ));
        }
      }
    }

    return Stack(
      children: [
        Listener(
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          child: MapboxMapWidget(
            key: ValueKey(_mapKey),
            accessToken: _token ?? '',
            center: widget.center,
            zoom: _currentZoom,
            style: widget.selectedLayer,
            points: mapPoints,
            checkpoints: checkpoints,
            onPointTap: _onPointOrCheckpointTap,
            onMapCreated: (map) {
              _map = map;
              map.setCamera(CameraOptions(
                center: Point(
                  coordinates: Position(
                    widget.center.longitude,
                    widget.center.latitude,
                  ),
                ),
                zoom: _currentZoom,
              ));
            },
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
                selfAvatarBytes: context.watch<LocalAvatarStore?>()?.bytes,
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
                icon: _autoFollow && _followedUserId == widget.selfProfile.id
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
          onExtentChanged: (fraction) => _sheetFraction = fraction,
        ),
      ],
    );
  }

  void _onPointOrCheckpointTap(String id) {
    if (id.startsWith('cluster-') || id.startsWith('event-')) return;
    final profile = widget.peers.firstWhere(
      (p) => p.id == id,
      orElse: () => widget.selfProfile,
    );
    _focusUser(profile);
  }
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
