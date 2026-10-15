import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../core/constants.dart';
import '../../../data/models/location_model.dart';
import '../../../data/models/user_model.dart';
import '../../calendar/calendar_events_provider.dart';
import '../../calendar/event_marker.dart';
import 'map_layers.dart';
import 'tracked_user_cluster_marker.dart';
import 'tracking_map_layer.dart';
import 'tracking_users_drawer.dart';
import '../local_avatar_store.dart';

/// Full extent the camera is kept within. `CameraConstraint.contain` rejects any
/// move whose viewport would spill outside these bounds, so the user can zoom
/// out until the world fills the screen but never into empty space around it,
/// and can't pan past the poles into the untiled grey void.
final LatLngBounds _worldBounds = LatLngBounds(
  const LatLng(-AppConstants.maxMercatorLatitude, -180),
  const LatLng(AppConstants.maxMercatorLatitude, 180),
);

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
    required this.selectedUserId,
    required this.onLayerSelected,
    required this.onUserSelected,
    required this.onStatusTap,
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
  final String? selectedUserId;
  final ValueChanged<MapLayer> onLayerSelected;
  final ValueChanged<UserProfile> onUserSelected;

  /// The sharing-status pill was tapped (opens the sharing settings).
  final VoidCallback onStatusTap;

  @override
  State<TrackingMapTab> createState() => _TrackingMapTabState();
}

class _TrackingMapTabState extends State<TrackingMapTab>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final Distance _distance = const Distance();
  late final AnimationController _mapCenterController;
  late final AnimationController _bearingController;

  // Gesture handling for rotation vs zoom discrimination
  final Map<int, Offset> _pointerLocations = {};
  double? _lastRotationAngle;
  bool _isRotationLocked = true;
  static const double _rotationThreshold = 15.0; // degrees of twist to unlock

  // Auto-follow: enabled when the user selects someone from the drawer,
  // disabled as soon as they manually pan/zoom the map.
  bool _autoFollow = false;
  String? _followedUserId;
  int _selectionTick = 0;

  // Fraction of the map's height the people sheet covers right now.
  double _sheetFraction = 0;

  // One motion per tracked marker (self + each peer), keyed by profile id, so
  // markers glide from their previous position to the new one instead of
  // teleporting whenever a fresh location arrives.
  final Map<String, _MarkerMotion> _motions = {};

  Animation<LatLng>? _mapCenterAnimation;
  Animation<double>? _mapZoomAnimation;
  Animation<double>? _bearingAnimation;

  // MapOptions.initialCenter is only read once, when the map is first built —
  // it's created before the device's real fix (fetched asynchronously) is
  // available, so it starts on the fallback center. Jump the camera to the
  // real fix the first time it arrives, unless the user has already panned
  // away from the fallback themselves.
  bool _didJumpToInitialFix = false;

  @override
  void initState() {
    super.initState();
    _mapCenterController = AnimationController(vsync: this)
      ..addListener(_handleMapCenterTick)
      ..addStatusListener(_handleMapCenterStatus);
    _bearingController = AnimationController(vsync: this)
      ..addListener(_handleBearingTick)
      ..addStatusListener(_handleBearingStatus);
    _syncMarkerMotions();
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
    // Don't fight the user if they've already started interacting with the map.
    if (_pointerLocations.isNotEmpty) return;
    _didJumpToInitialFix = true;
    _mapController.move(widget.center, _currentZoom);
  }

  @override
  void dispose() {
    _mapCenterController
      ..removeListener(_handleMapCenterTick)
      ..removeStatusListener(_handleMapCenterStatus)
      ..dispose();
    _bearingController
      ..removeListener(_handleBearingTick)
      ..removeStatusListener(_handleBearingStatus)
      ..dispose();
    for (final motion in _motions.values) {
      motion.dispose();
    }
    _motions.clear();
    _mapController.dispose();
    super.dispose();
  }

  double get _currentZoom {
    try {
      return _mapController.camera.zoom;
    } catch (_) {
      return AppConstants.defaultZoom;
    }
  }

  double _selectedZoomForSelection() {
    final currentZoom = _currentZoom;
    return math.min(
      AppConstants.maxZoom,
      math.max(currentZoom, AppConstants.defaultZoom + 3.5),
    );
  }

  void _animateMapTo(LatLng target, {double? zoomTarget}) {
    if (!target.latitude.isFinite || !target.longitude.isFinite) {
      return;
    }

    LatLng start;
    try {
      start = _mapController.camera.center;
    } catch (_) {
      start = widget.center;
    }

    if (!start.latitude.isFinite || !start.longitude.isFinite) {
      start = target;
    }

    final targetZoom = zoomTarget ?? _currentZoom;
    if (start == target && targetZoom == _currentZoom) {
      return;
    }

    final duration = _movementDuration(start, target);
    _mapCenterController.stop();
    _mapCenterAnimation = _LatLngTween(begin: start, end: target).animate(
      CurvedAnimation(parent: _mapCenterController, curve: Curves.easeOutCubic),
    );
    _mapZoomAnimation = Tween<double>(begin: _currentZoom, end: targetZoom)
        .animate(
          CurvedAnimation(
            parent: _mapCenterController,
            curve: Curves.easeOutCubic,
          ),
        );
    _mapCenterController.duration = duration;
    _mapCenterController.forward(from: 0);
  }

  void _handleMapCenterTick() {
    if (!mounted || !widget.isActive) {
      return;
    }

    final animatedCenter = _mapCenterAnimation?.value;
    final animatedZoom = _mapZoomAnimation?.value ?? _currentZoom;
    if (animatedCenter == null) {
      return;
    }

    _mapController.move(animatedCenter, animatedZoom);
  }

  void _handleMapCenterStatus(AnimationStatus status) {
    // Only clean up after the animation fully completes. dismissed fires when
    // forward(from: 0) resets the controller value to 0, but _mapCenterAnimation
    // has already been replaced with the new animation at that point — clearing
    // it here would make every subsequent tick a no-op.
    if (status == AnimationStatus.completed) {
      _mapCenterAnimation = null;
      _mapZoomAnimation = null;
    }
  }

  void _handleBearingTick() {
    if (!mounted || !widget.isActive) {
      return;
    }
    final animatedBearing = _bearingAnimation?.value;
    if (animatedBearing == null) {
      return;
    }
    _mapController.rotate(animatedBearing);
  }

  void _handleBearingStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _bearingAnimation = null;
    }
  }

  Duration _movementDuration(LatLng start, LatLng end) {
    final meters = _distance.as(LengthUnit.Meter, start, end);
    final milliseconds = (80 + math.sqrt(meters) * 12).clamp(80, 450);
    return Duration(milliseconds: milliseconds.round());
  }

  /// Feeds the latest location of self and every peer into its motion, so each
  /// marker glides to the new position, and disposes motions for users that are
  /// no longer present.
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

  /// Tapping a marker does what tapping their row does: open their details
  /// and bring them into the part of the map the sheet leaves visible.
  void _selectUser(UserProfile profile) => _focusUser(profile);

  void _focusUser(UserProfile profile) {
    // Re-selecting the same person must still reopen their details.
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

  /// Centers on ourselves without opening our details: the button means
  /// "where am I", not "show me my stats".
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
    final zoom = _selectedZoomForSelection();
    _animateMapTo(
      _centerShowing(
        LatLng(location.latitude, location.longitude),
        zoom,
        sheetFraction,
      ),
      zoomTarget: zoom,
    );
  }

  /// The camera center that puts [point] in the middle of the part of the
  /// map the people sheet leaves visible, rather than hidden behind it.
  LatLng _centerShowing(LatLng point, double zoom, double sheetFraction) {
    final MapCamera camera;
    try {
      camera = _mapController.camera;
    } catch (_) {
      return point;
    }
    final covered = sheetFraction * camera.nonRotatedSize.height;
    if (covered <= 0) return point;
    return CameraFit.coordinates(
      coordinates: [point],
      padding: EdgeInsets.only(bottom: covered),
      minZoom: zoom,
      maxZoom: zoom,
    ).fit(camera).center;
  }

  void _animateBearingToNorth() {
    final currentBearing = _mapController.camera.rotation;
    if (!currentBearing.isFinite) {
      return;
    }

    _bearingController.stop();
    _bearingAnimation = Tween<double>(begin: currentBearing, end: 0.0).animate(
      CurvedAnimation(parent: _bearingController, curve: Curves.easeOutCubic),
    );
    _bearingController.duration = const Duration(milliseconds: 600);
    _bearingController.forward(from: 0);
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pointerLocations[event.pointer] = event.position;
    _isRotationLocked = true;
    _lastRotationAngle = null;
    // Hand camera control to the user: cancel any in-flight programmatic camera
    // animation so it can't fight the gesture. A move() landing mid-pinch
    // corrupts flutter_map's focal-point math and flings the map off-screen.
    _mapCenterController.stop();
    _bearingController.stop();
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _pointerLocations[event.pointer] = event.position;

    // Calculate rotation angle if we have two fingers
    if (_pointerLocations.length >= 2) {
      final positions = _pointerLocations.values.toList();
      if (positions.length >= 2) {
        final angle = _calculateRotationAngle(positions[0], positions[1]);

        if (_lastRotationAngle != null) {
          final angleDelta = (angle - _lastRotationAngle!).abs();
          // Normalize angle delta to 0-180 range
          final normalizedDelta = angleDelta > 180
              ? 360 - angleDelta
              : angleDelta;

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

  void _handleMotionTick() {
    if (!mounted) return;
    setState(() {});
    _syncMapCameraToFollowedUser();
  }

  void _syncMapCameraToFollowedUser() {
    if (!mounted || !widget.isActive) return;
    if (!_autoFollow) return;
    // Never move the camera while the user is touching the map: a move() during
    // a pinch/drag desyncs flutter_map's gesture math and the map can vanish.
    if (_pointerLocations.isNotEmpty) return;
    // Let a deliberate focus animation (e.g. initial user selection) finish
    // before the motion tick takes over camera control.
    if (_mapCenterController.isAnimating) return;
    final followedId =
        _followedUserId ?? widget.selectedUserId ?? widget.selfProfile.id;
    final pos = _motions[followedId]?.value;
    if (pos == null) return;
    final zoom = _currentZoom;
    _mapController.move(_centerShowing(pos, zoom, _sheetFraction), zoom);
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final events = context.watch<CalendarEventsProvider?>();
    return Stack(
      children: [
        Listener(
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: widget.center,
              initialZoom: AppConstants.defaultZoom,
              minZoom: AppConstants.minZoom,
              maxZoom: AppConstants.maxZoom,
              // Keep the viewport inside the tiled world: stops zoom-out into
              // empty space and panning past the poles.
              cameraConstraint: CameraConstraint.contain(bounds: _worldBounds),
              keepAlive: true,
              // Disable default rotation to handle it manually with threshold
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (camera, hasGesture) {
                if (hasGesture && _autoFollow) {
                  setState(() => _autoFollow = false);
                }
              },
            ),
            children: [
              ...buildMapTileLayers(widget.selectedLayer),
              // Under the people, so an event never hides someone's marker.
              if (events != null && events.visibleEvents.isNotEmpty)
                MarkerLayer(
                  markers: [
                    for (final event in events.visibleEvents)
                      Marker(
                        point: event.point!,
                        width: EventMarker.size,
                        height: EventMarker.size,
                        child: EventMarker(
                          event: event,
                          onTap: () => showEventDetails(context, event),
                        ),
                      ),
                  ],
                ),
              // MapCamera.of rebuilds this on every camera change, so groups
              // split and merge live while zooming instead of on the next tick.
              Builder(
                builder: (context) =>
                    MarkerLayer(markers: _buildMarkers(MapCamera.of(context))),
              ),
            ],
          ),
        ),
        // Keeps the status bar's clock and icons legible over light tiles.
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
          child: _SharingStatusPill(
            paused: widget.selfTrackingPaused,
            missingPermissions: widget.selfMissingPermissions,
            live: widget.selfLive,
            onTap: widget.onStatusTap,
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

  /// Screen-pixel distance under which two markers are folded into one
  /// cluster bubble instead of being drawn as separate (overlapping,
  /// indistinguishable) pins. Sized to the marker's full visual footprint —
  /// the 60px avatar circle plus the speed/battery badges and pulse ring
  /// that extend beyond it — not just the avatar itself, otherwise two
  /// markers can visually collide (badges overlapping, one covering the
  /// other's tap target) while staying just outside the threshold.
  static const double _clusterPixelRadius = 96;

  /// Real-world distance under which markers may be folded together. The
  /// pixel radius alone shrinks in metres as the map zooms out, which would
  /// merge people kilometres apart; this keeps a cluster meaning "actually
  /// together". Both limits must hold.
  static const double clusterMaxMeters = 100;
  static const Distance _geoDistance = Distance();

  List<Marker> _buildMarkers(MapCamera camera) {
    final clusters = _clusterEntries(_collectMarkerEntries(), camera);
    return [for (final cluster in clusters) _buildClusterMarker(cluster)];
  }

  /// Self (if it has a fix) plus every peer with a fix, paired with their
  /// current animated on-screen position.
  List<_UserMarkerEntry> _collectMarkerEntries() {
    final entries = <_UserMarkerEntry>[];

    final selfLocation = widget.selfProfile.lastLocation;
    if (selfLocation != null &&
        selfLocation.latitude.isFinite &&
        selfLocation.longitude.isFinite) {
      entries.add(
        _UserMarkerEntry(
          profile: widget.selfProfile,
          location: selfLocation,
          point:
              _motions[widget.selfProfile.id]?.value ??
              LatLng(selfLocation.latitude, selfLocation.longitude),
          isSelf: true,
        ),
      );
    }

    for (final peer in widget.peers) {
      final location = peer.lastLocation;
      if (location == null ||
          !location.latitude.isFinite ||
          !location.longitude.isFinite) {
        continue;
      }
      entries.add(
        _UserMarkerEntry(
          profile: peer,
          location: location,
          point:
              _motions[peer.id]?.value ??
              LatLng(location.latitude, location.longitude),
          isSelf: false,
        ),
      );
    }

    return entries;
  }

  /// Greedily groups entries whose projected screen position falls within
  /// [_clusterPixelRadius] *and* whose real position falls within
  /// [clusterMaxMeters] of an existing cluster's running centroid. Cheap
  /// and order-dependent, but with only a handful of tracked users on screen
  /// at once the result is visually indistinguishable from an optimal
  /// grouping.
  List<List<_UserMarkerEntry>> _clusterEntries(
    List<_UserMarkerEntry> entries,
    MapCamera camera,
  ) {
    if (entries.length <= 1) {
      return [
        for (final entry in entries) [entry],
      ];
    }

    final clusters = <List<_UserMarkerEntry>>[];
    final centroids = <Offset>[];
    final geoCentroids = <LatLng>[];
    for (final entry in entries) {
      final px = camera.projectAtZoom(entry.point);
      var placedIndex = -1;
      for (var i = 0; i < clusters.length; i++) {
        if ((px - centroids[i]).distance <= _clusterPixelRadius &&
            _geoDistance(entry.point, geoCentroids[i]) <= clusterMaxMeters) {
          placedIndex = i;
          break;
        }
      }
      if (placedIndex == -1) {
        clusters.add([entry]);
        centroids.add(px);
        geoCentroids.add(entry.point);
      } else {
        clusters[placedIndex].add(entry);
        final members = clusters[placedIndex];
        final sum = members.fold<Offset>(
          Offset.zero,
          (sum, member) => sum + camera.projectAtZoom(member.point),
        );
        centroids[placedIndex] = sum / members.length.toDouble();
        geoCentroids[placedIndex] = LatLng(
          members.fold<double>(0, (t, m) => t + m.point.latitude) /
              members.length,
          members.fold<double>(0, (t, m) => t + m.point.longitude) /
              members.length,
        );
      }
    }
    return clusters;
  }

  Marker _buildClusterMarker(List<_UserMarkerEntry> members) {
    return Marker(
      point: _centroid(members.map((m) => m.point)),
      width: TrackedUserClusterMarker.widthFor(members.length),
      height: TrackedUserClusterMarker.height,
      // The dot at the tail's tip is what sits on the location.
      alignment: TrackedUserClusterMarker.alignmentFor(members.length),
      child: TrackedUserClusterMarker(
        members: [
          for (final m in members)
            ClusterMember(
              id: m.profile.id,
              name: m.isSelf ? '${m.profile.name} (you)' : m.profile.name,
              avatarUrl: m.profile.avatarUrl,
              isStale: _isStale(m.profile),
              isSelected: widget.selectedUserId == m.profile.id,
              avatarBytes: m.isSelf
                  ? context.watch<LocalAvatarStore?>()?.bytes
                  : null,
              onTap: () => _selectUser(m.profile),
            ),
        ],
        onTap: () => _focusCluster(members),
        accentColor: const Color(0xFF0985FB),
      ),
    );
  }

  LatLng _centroid(Iterable<LatLng> points) {
    var lat = 0.0;
    var lng = 0.0;
    var count = 0;
    for (final point in points) {
      lat += point.latitude;
      lng += point.longitude;
      count++;
    }
    return LatLng(lat / count, lng / count);
  }

  /// Zooms the map in to separate a tapped cluster into its individual
  /// members, Life360-style, rather than opening any one member's detail.
  void _focusCluster(List<_UserMarkerEntry> members) {
    if (members.length == 1) {
      _focusUser(members.first.profile);
      return;
    }

    final MapCamera camera;
    try {
      camera = _mapController.camera;
    } catch (_) {
      return;
    }

    final fitted = CameraFit.coordinates(
      coordinates: members.map((m) => m.point).toList(),
      padding: const EdgeInsets.all(90),
      maxZoom: AppConstants.maxZoom,
    ).fit(camera);

    setState(() => _autoFollow = false);
    _animateMapTo(
      _centerShowing(fitted.center, fitted.zoom, _sheetFraction),
      zoomTarget: fitted.zoom,
    );
  }

  /// Greyed out when we haven't heard from the device in a while. Uses the
  /// server's last-seen time, not the position's age: a parked user's last
  /// point is old by design (nothing is recorded while stationary) yet they
  /// are still online, refreshing last-seen with heartbeats and live pings.
  bool _isStale(UserProfile profile) {
    if (profile.id == widget.selfProfile.id) return false;
    return profile.isStale;
  }
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

/// A trackable user (self or peer) paired with their current animated
/// on-screen position, used as the unit clustering groups together.
class _UserMarkerEntry {
  _UserMarkerEntry({
    required this.profile,
    required this.location,
    required this.point,
    required this.isSelf,
  });

  final UserProfile profile;
  final LocationPoint location;
  final LatLng point;
  final bool isSelf;
}

/// Drives the on-screen position of a single marker, tweening it from its
/// current position to each new location instead of jumping there instantly.
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
  /// point so the marker glides rather than teleports.
  ///
  /// Movement is keyed on the target coordinates rather than the location's
  /// timestamp: peer timestamps come from the server's `recorded_at`, which can
  /// repeat across updates, whereas a changed position is exactly what should
  /// trigger a glide. The glide stretches across roughly the real gap between
  /// updates so the marker is continuously in motion rather than hopping and
  /// then sitting still until the next fix arrives.
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
