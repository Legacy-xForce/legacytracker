import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants.dart';
import '../../../data/models/location_model.dart';
import '../../../data/models/user_model.dart';
import 'tracking_map_layer.dart';
import 'tracking_users_drawer.dart';

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
    required this.selectedUserId,
    required this.onLayerSelected,
    required this.onUserSelected,
    required this.onUserTap,
  });

  final bool isActive;
  final LatLng center;
  final MapLayer selectedLayer;
  final List<UserProfile> peers;
  final UserProfile selfProfile;
  final bool selfTrackingPaused;
  final bool selfMissingPermissions;
  final bool selfBatterySavingEnabled;
  final String? selectedUserId;
  final ValueChanged<MapLayer> onLayerSelected;
  final ValueChanged<UserProfile> onUserSelected;
  final ValueChanged<UserProfile> onUserTap;

  @override
  State<TrackingMapTab> createState() => _TrackingMapTabState();
}

class _TrackingMapTabState extends State<TrackingMapTab>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final Distance _distance = const Distance();
  late final AnimationController _pulseController;
  late final AnimationController _mapCenterController;

  // One motion per tracked marker (self + each peer), keyed by profile id, so
  // markers glide from their previous position to the new one instead of
  // teleporting whenever a fresh location arrives.
  final Map<String, _MarkerMotion> _motions = {};

  Animation<LatLng>? _mapCenterAnimation;
  Animation<double>? _mapZoomAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _mapCenterController = AnimationController(vsync: this)
      ..addListener(_handleMapCenterTick)
      ..addStatusListener(_handleMapCenterStatus);
    _syncMovementPulse();
    _syncMarkerMotions();
  }

  @override
  void didUpdateWidget(covariant TrackingMapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMovementPulse();
    _syncMarkerMotions();

  }

  @override
  void dispose() {
    _mapCenterController
      ..removeListener(_handleMapCenterTick)
      ..removeStatusListener(_handleMapCenterStatus)
      ..dispose();
    for (final motion in _motions.values) {
      motion.dispose();
    }
    _motions.clear();
    _pulseController.dispose();
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

  Duration _movementDuration(LatLng start, LatLng end) {
    final meters = _distance.as(LengthUnit.Meter, start, end);
    final milliseconds = (80 + math.sqrt(meters) * 12).clamp(80, 450);
    return Duration(milliseconds: milliseconds.round());
  }

  void _syncMovementPulse() {
    final isMoving = widget.selfProfile.lastLocation?.isMoving ?? false;
    if (isMoving) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      if (_pulseController.isAnimating) {
        _pulseController.stop();
      }
      _pulseController.value = 0;
    }
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

  void _selectUser(UserProfile profile) {
    widget.onUserSelected(profile);
    widget.onUserTap(profile);
  }

  void _focusUser(UserProfile profile) {
    final location = profile.lastLocation;
    if (location == null ||
        !location.latitude.isFinite ||
        !location.longitude.isFinite) {
      widget.onUserSelected(profile);
      return;
    }

    widget.onUserSelected(profile);

    _animateMapTo(
      LatLng(location.latitude, location.longitude),
      zoomTarget: _selectedZoomForSelection(),
    );
  }

  void _handleMotionTick() {
    if (!mounted) return;
    setState(() {});
    _syncMapCameraToFollowedUser();
  }

  void _syncMapCameraToFollowedUser() {
    if (!mounted || !widget.isActive) return;
    // Let a deliberate focus animation (e.g. initial user selection) finish
    // before the motion tick takes over camera control.
    if (_mapCenterController.isAnimating) return;
    final followedId = widget.selectedUserId ?? widget.selfProfile.id;
    final pos = _motions[followedId]?.value;
    if (pos == null) return;
    _mapController.move(pos, _currentZoom);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: widget.center,
            initialZoom: AppConstants.defaultZoom,
            minZoom: AppConstants.minZoom,
            maxZoom: AppConstants.maxZoom,
            keepAlive: true,
          ),
          children: [
            ..._buildLayers(),
            MarkerLayer(
              markers: [
                ..._buildPeerMarkers(),
                if (widget.selfProfile.lastLocation != null) _buildSelfMarker(),
              ],
            ),
          ],
        ),
        TrackingUsersDrawer(
          selfProfile: widget.selfProfile,
          peers: widget.peers,
          selfTrackingPaused: widget.selfTrackingPaused,
          selfMissingPermissions: widget.selfMissingPermissions,
          selfBatterySavingEnabled: widget.selfBatterySavingEnabled,
          selectedUserId: widget.selectedUserId,
          onUserSelected: _focusUser,
        ),
        Positioned(
          top: 16,
          right: 16,
          child: PopupMenuButton<MapLayer>(
            initialValue: widget.selectedLayer,
            onSelected: widget.onLayerSelected,
            itemBuilder: (BuildContext context) => const [
              PopupMenuItem(value: MapLayer.standard, child: Text('Standard')),
              PopupMenuItem(
                value: MapLayer.satellite,
                child: Text('Satellite'),
              ),
              PopupMenuItem(value: MapLayer.terrain, child: Text('Terrain')),
            ],
            child: FloatingActionButton(
              mini: true,
              onPressed: null,
              child: const Icon(Icons.layers),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildLayers() {
    switch (widget.selectedLayer) {
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
            urlTemplate:
                'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
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

  List<Marker> _buildPeerMarkers() {
    return widget.peers.map((peer) {
      final location = peer.lastLocation;
      if (location == null ||
          !location.latitude.isFinite ||
          !location.longitude.isFinite) {
        return Marker(
          point: AppConstants.defaultMapCenter,
          width: 0,
          height: 0,
          child: const SizedBox.shrink(),
        );
      }

      final point =
          _motions[peer.id]?.value ??
          LatLng(location.latitude, location.longitude);
      return _buildTrackedUserMarker(
        profile: peer,
        location: location,
        point: point,
        isSelected: widget.selectedUserId == peer.id,
        onTap: () => _selectUser(peer),
        tooltipMessage: peer.name,
        beamColor: const Color(0xFF0985FB),
        ringColor: Colors.white,
        badgeColor: Colors.grey.shade900,
      );
    }).toList();
  }

  Marker _buildSelfMarker() {
    final profile = widget.selfProfile;
    final location = profile.lastLocation!;
    if (!location.latitude.isFinite || !location.longitude.isFinite) {
      return Marker(
        point: AppConstants.defaultMapCenter,
        width: 0,
        height: 0,
        child: const SizedBox.shrink(),
      );
    }

    final markerLocation =
        _motions[profile.id]?.value ??
        LatLng(location.latitude, location.longitude);
    return _buildTrackedUserMarker(
      profile: profile,
      location: location,
      point: markerLocation,
      isSelected: widget.selectedUserId == profile.id,
      onTap: () => _selectUser(profile),
      tooltipMessage: '${profile.name} (you)',
      beamColor: const Color(0xFF0985FB),
      ringColor: const Color(0xFF0985FB),
      badgeColor: Colors.teal.shade800,
    );
  }

  Marker _buildTrackedUserMarker({
    required UserProfile profile,
    required LocationPoint location,
    required LatLng point,
    required bool isSelected,
    required VoidCallback onTap,
    required String tooltipMessage,
    required Color beamColor,
    required Color ringColor,
    required Color badgeColor,
  }) {
    final speed = location.speed * 3.6;
    final isMoving = location.isMoving;
    final heading = _headingFor(location);
    final isStale = _isLocationStale(location);
    final displayBeamColor = isStale ? Colors.grey.shade500 : beamColor;
    final displayRingColor = isStale ? Colors.grey.shade500 : ringColor;
    final displayBadgeColor = isStale ? Colors.grey.shade700 : badgeColor;
    final batteryLevel = profile.batteryLevel;
    final displayBatteryLevel = batteryLevel?.clamp(0, 100).toInt();

    return Marker(
      point: point,
      width: 152,
      height: 168,
      child: GestureDetector(
        onTap: onTap,
        child: Tooltip(
          message: tooltipMessage,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(
              end: isSelected ? 1.18 : (isMoving ? 1.08 : 1.0),
            ),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            builder: (context, scale, child) {
              return Transform.scale(scale: scale, child: child);
            },
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (heading != null && isMoving)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedRotation(
                        turns: heading / 360.0,
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        child: CustomPaint(
                          painter: _HeadingBeamPainter(
                            beamColor: displayBeamColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (isMoving)
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final t = Curves.easeOut.transform(
                        _pulseController.value,
                      );
                      return Container(
                        width: 58 + (22 * t),
                        height: 58 + (22 * t),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: displayBeamColor.withValues(
                            alpha: 0.22 * (1 - t),
                          ),
                        ),
                      );
                    },
                  ),
                ColorFiltered(
                  colorFilter: isStale
                      ? const ColorFilter.matrix(<double>[
                          0.2126,
                          0.7152,
                          0.0722,
                          0,
                          0,
                          0.2126,
                          0.7152,
                          0.0722,
                          0,
                          0,
                          0.2126,
                          0.7152,
                          0.0722,
                          0,
                          0,
                          0,
                          0,
                          0,
                          1,
                          0,
                        ])
                      : const ColorFilter.mode(
                          Colors.transparent,
                          BlendMode.srcOver,
                        ),
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isMoving ? Colors.teal.shade600 : Colors.teal,
                      border: Border.all(color: displayRingColor, width: 4),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: CircleAvatar(
                      radius: 24,
                      backgroundColor: Colors.white,
                      backgroundImage: profile.avatarUrl.isNotEmpty
                          ? NetworkImage(profile.avatarUrl)
                          : null,
                      child: profile.avatarUrl.isEmpty
                          ? Text(profile.name.characters.first.toUpperCase())
                          : null,
                    ),
                  ),
                ),
                Positioned(
                  top: 48,
                  right: 18,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: displayBadgeColor,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.speed_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${speed.toStringAsFixed(1)} km/h',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (displayBatteryLevel != null)
                  Positioned(
                    top: 0,
                    left: 16,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: displayBadgeColor,
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.battery_full_rounded,
                            size: 12,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$displayBatteryLevel%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double? _headingFor(LocationPoint location) {
    final heading = location.heading;
    if (heading == null || !heading.isFinite) {
      return null;
    }
    return normalizeBearing(heading);
  }

  bool _isLocationStale(LocationPoint location) {
    return DateTime.now().difference(location.timestamp) >
        const Duration(minutes: 2);
  }
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

class _HeadingBeamPainter extends CustomPainter {
  _HeadingBeamPainter({required this.beamColor});

  final Color beamColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 4);
    final outerRadius = size.height * 0.46;

    // 56° total cone (±28° from the upward axis)
    const halfAngle = 28.0 * math.pi / 180.0;
    const upAngle = -math.pi / 2;

    final arcRect = Rect.fromCircle(center: center, radius: outerRadius);
    final conePath = ui.Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(arcRect, upAngle - halfAngle, halfAngle * 2, false)
      ..close();

    // Blurred glow layer drawn first to feather the straight edges
    final glowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = beamColor.withValues(alpha: 0.12)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    canvas.drawPath(conePath, glowPaint);

    // Main beam: radial gradient from ~50% opacity at user position to 0% at outer arc
    final gradientPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: [
          beamColor.withValues(alpha: 0.50),
          beamColor.withValues(alpha: 0.0),
        ],
      ).createShader(arcRect);
    canvas.drawPath(conePath, gradientPaint);
  }

  @override
  bool shouldRepaint(covariant _HeadingBeamPainter oldDelegate) {
    return oldDelegate.beamColor != beamColor;
  }
}
