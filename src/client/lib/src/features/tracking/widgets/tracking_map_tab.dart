import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants.dart';
import '../../../data/models/location_model.dart';
import '../../../data/models/user_model.dart';
import 'tracking_map_layer.dart';

class TrackingMapTab extends StatefulWidget {
  const TrackingMapTab({
    super.key,
    required this.isActive,
    required this.center,
    required this.selectedLayer,
    required this.peers,
    required this.selfProfile,
    required this.onLayerSelected,
    required this.onUserTap,
  });

  final bool isActive;
  final LatLng center;
  final MapLayer selectedLayer;
  final List<UserProfile> peers;
  final UserProfile selfProfile;
  final ValueChanged<MapLayer> onLayerSelected;
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
  late final AnimationController _selfMarkerController;

  Animation<LatLng>? _mapCenterAnimation;
  Animation<LatLng>? _selfMarkerAnimation;
  LatLng? _displayedSelfLocation;
  LatLng? _lastCenteredLocation;
  DateTime? _lastAnimatedSelfTimestamp;

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
    _selfMarkerController = AnimationController(vsync: this)
      ..addListener(_handleSelfMarkerTick)
      ..addStatusListener(_handleSelfMarkerStatus);
    _displayedSelfLocation = _currentSelfLocation;
    _lastAnimatedSelfTimestamp = widget.selfProfile.lastLocation?.timestamp;
    _syncMovementPulse();
  }

  @override
  void didUpdateWidget(covariant TrackingMapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMovementPulse();
    _syncSelfMarkerAnimation();

    if (!widget.isActive) {
      return;
    }

    if (_lastCenteredLocation != widget.center) {
      _lastCenteredLocation = widget.center;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.isActive) return;
        _animateMapTo(widget.center);
      });
    }
  }

  @override
  void dispose() {
    _mapCenterController
      ..removeListener(_handleMapCenterTick)
      ..removeStatusListener(_handleMapCenterStatus)
      ..dispose();
    _selfMarkerController
      ..removeListener(_handleSelfMarkerTick)
      ..removeStatusListener(_handleSelfMarkerStatus)
      ..dispose();
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

  LatLng? get _currentSelfLocation {
    final location = widget.selfProfile.lastLocation;
    if (location == null ||
        !location.latitude.isFinite ||
        !location.longitude.isFinite) {
      return null;
    }
    return LatLng(location.latitude, location.longitude);
  }

  void _animateMapTo(LatLng target) {
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

    if (start == target) {
      return;
    }

    final duration = _movementDuration(start, target);
    _mapCenterController.stop();
    _mapCenterAnimation = _LatLngTween(begin: start, end: target).animate(
      CurvedAnimation(parent: _mapCenterController, curve: Curves.easeOutCubic),
    );
    _mapCenterController.duration = duration;
    _mapCenterController.forward(from: 0);
  }

  void _handleMapCenterTick() {
    if (!mounted || !widget.isActive) {
      return;
    }

    final animatedCenter = _mapCenterAnimation?.value;
    if (animatedCenter == null) {
      return;
    }

    _mapController.move(animatedCenter, _currentZoom);
  }

  void _handleMapCenterStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _mapCenterAnimation = null;
    }
  }

  void _handleSelfMarkerTick() {
    if (!mounted) {
      return;
    }

    final animatedLocation = _selfMarkerAnimation?.value;
    if (animatedLocation == null) {
      return;
    }

    setState(() {
      _displayedSelfLocation = animatedLocation;
    });
  }

  void _handleSelfMarkerStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      final location = _currentSelfLocation;
      if (location != null && mounted) {
        setState(() {
          _displayedSelfLocation = location;
        });
      }
      _selfMarkerAnimation = null;
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

  void _syncSelfMarkerAnimation() {
    final location = widget.selfProfile.lastLocation;
    if (location == null) {
      _displayedSelfLocation = null;
      _lastAnimatedSelfTimestamp = null;
      return;
    }

    if (!location.latitude.isFinite || !location.longitude.isFinite) {
      _displayedSelfLocation = null;
      _lastAnimatedSelfTimestamp = null;
      return;
    }

    if (_lastAnimatedSelfTimestamp == location.timestamp) {
      return;
    }

    final target = LatLng(location.latitude, location.longitude);
    final start = _displayedSelfLocation ?? target;
    _lastAnimatedSelfTimestamp = location.timestamp;

    if (start == target) {
      setState(() {
        _displayedSelfLocation = target;
      });
      return;
    }

    final duration = _movementDuration(start, target);
    _selfMarkerController.stop();
    _selfMarkerAnimation = _LatLngTween(begin: start, end: target).animate(
      CurvedAnimation(
        parent: _selfMarkerController,
        curve: Curves.easeOutCubic,
      ),
    );
    _selfMarkerController.duration = duration;
    _selfMarkerController.forward(from: 0);
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
                'https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}',
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

      return _buildTrackedUserMarker(
        profile: peer,
        location: location,
        point: LatLng(location.latitude, location.longitude),
        onTap: () => widget.onUserTap(peer),
        tooltipMessage: peer.name,
        beamColor: const Color(0xFF8B5CF6),
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
        _displayedSelfLocation ?? LatLng(location.latitude, location.longitude);
    return _buildTrackedUserMarker(
      profile: profile,
      location: location,
      point: markerLocation,
      onTap: () => widget.onUserTap(profile),
      tooltipMessage: '${profile.name} (you)',
      beamColor: const Color(0xFF8B5CF6),
      ringColor: const Color(0xFF8B5CF6),
      badgeColor: Colors.teal.shade800,
    );
  }

  Marker _buildTrackedUserMarker({
    required UserProfile profile,
    required LocationPoint location,
    required LatLng point,
    required VoidCallback onTap,
    required String tooltipMessage,
    required Color beamColor,
    required Color ringColor,
    required Color badgeColor,
  }) {
    final speed = location.speed;
    final isMoving = location.isMoving;
    final heading = _headingFor(location);

    return Marker(
      point: point,
      width: 152,
      height: 168,
      child: GestureDetector(
        onTap: onTap,
        child: Tooltip(
          message: tooltipMessage,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: isMoving ? 1.08 : 1.0),
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
                          painter: _HeadingBeamPainter(beamColor: beamColor),
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
                          color: beamColor.withValues(alpha: 0.22 * (1 - t)),
                        ),
                      );
                    },
                  ),
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isMoving ? Colors.teal.shade600 : Colors.teal,
                    border: Border.all(color: ringColor, width: 4),
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
                      color: badgeColor,
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
                          '${speed.toStringAsFixed(1)} m/s',
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
    final tip = Offset(size.width / 2, size.height * 0.08);
    final outerLeft = Offset(size.width * 0.18, size.height * 0.38);
    final outerRight = Offset(size.width * 0.82, size.height * 0.38);
    final innerLeft = Offset(size.width * 0.30, size.height * 0.50);
    final innerRight = Offset(size.width * 0.70, size.height * 0.50);

    final outerPath = ui.Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(outerLeft.dx, outerLeft.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(outerRight.dx, outerRight.dy)
      ..close();

    final innerPath = ui.Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(innerLeft.dx, innerLeft.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(innerRight.dx, innerRight.dy)
      ..close();

    final outerPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          beamColor.withValues(alpha: 0.28),
          beamColor.withValues(alpha: 0.05),
        ],
      ).createShader(Offset.zero & size);

    final innerPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          beamColor.withValues(alpha: 0.55),
          beamColor.withValues(alpha: 0.12),
        ],
      ).createShader(Offset.zero & size);

    canvas.drawPath(outerPath, outerPaint);
    canvas.drawPath(innerPath, innerPaint);

    final glowPaint = Paint()
      ..color = beamColor.withValues(alpha: 0.12)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawPath(outerPath, glowPaint);
  }

  @override
  bool shouldRepaint(covariant _HeadingBeamPainter oldDelegate) {
    return oldDelegate.beamColor != beamColor;
  }
}
