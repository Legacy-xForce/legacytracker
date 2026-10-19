import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../core/formatters.dart';
import '../../../core/speed_color.dart';
import '../../../data/models/location_session.dart';
import '../map_settings.dart';
import 'map_layers.dart';
import 'tracked_user_marker.dart';
import 'tracking_map_layer.dart';

class SessionReplayScreen extends StatefulWidget {
  const SessionReplayScreen({
    super.key,
    required this.session,
    required this.userId,
    required this.userName,
  });

  final LocationSession session;
  final String userId;
  final String userName;

  @override
  State<SessionReplayScreen> createState() => _SessionReplayScreenState();
}

class _SessionReplayScreenState extends State<SessionReplayScreen>
    with SingleTickerProviderStateMixin {
  // Constant on-screen speed, independent of the recorded real speed. Points
  // are stored adaptively — dense through turns, sparse on straights — so
  // each glide lasts in proportion to the distance it covers; a fixed time
  // per segment would race down straights and crawl through corners. The
  // pace is set so a whole session plays in about this long at 1x.
  static const _targetPlayback = Duration(seconds: 40);
  // Every speed option plays this many times faster than the pace above:
  // "1x" covers a trip in ~20 s, "4x" in ~5 s.
  static const _baseSpeed = 2.0;
  static const _minPaceMetersPerSecond = 5.0;
  static const _minSegmentMs = 16.0; // one frame
  static const _maxSegmentMs = 3000.0; // e.g. across a GPS gap

  final MapController _mapController = MapController();
  late final AnimationController _segmentController;
  Animation<LatLng>? _segmentAnimation;

  late MapLayer _selectedLayer = context.read<MapSettings>().defaultLayer;
  double _playbackSpeed = 1.0;
  int _segmentStart = 0;
  LatLng? _displayedPoint;
  bool _isPlaying = false;

  late final List<LatLng> _route = widget.session.points
      .map((p) => LatLng(p.latitude, p.longitude))
      .toList();

  late final List<double> _segmentMeters = [
    for (var i = 1; i < _route.length; i++)
      const Distance().as(LengthUnit.Meter, _route[i - 1], _route[i]),
  ];

  /// The route as runs of one speed colour, red when slow and green when fast.
  late final List<Polyline> _speedPolylines = _buildSpeedPolylines();

  List<Polyline> _buildSpeedPolylines() {
    final points = widget.session.points;
    final polylines = <Polyline>[];
    for (var i = 1; i < points.length; i++) {
      final color = speedColor((points[i - 1].speed + points[i].speed) / 2);
      if (polylines.isNotEmpty && polylines.last.color == color) {
        polylines.last.points.add(_route[i]);
      } else {
        polylines.add(
          Polyline(
            points: [_route[i - 1], _route[i]],
            strokeWidth: 5,
            color: color,
            strokeCap: StrokeCap.round,
            strokeJoin: StrokeJoin.round,
          ),
        );
      }
    }
    return polylines;
  }

  late final double _paceMetersPerSecond = math.max(
    _segmentMeters.fold<double>(0, (sum, m) => sum + m) /
        _targetPlayback.inSeconds,
    _minPaceMetersPerSecond,
  );

  @override
  void initState() {
    super.initState();
    _segmentController = AnimationController(vsync: this)
      ..addListener(_handleSegmentTick)
      ..addStatusListener(_handleSegmentStatus);
    _displayedPoint = _route.isNotEmpty ? _route.first : null;
  }

  @override
  void dispose() {
    _segmentController
      ..removeListener(_handleSegmentTick)
      ..removeStatusListener(_handleSegmentStatus)
      ..dispose();
    super.dispose();
  }

  void _togglePlay() => _isPlaying ? _pause() : _play();

  void _play() {
    if (widget.session.points.length < 2) return;
    if (_segmentStart >= widget.session.points.length - 1) {
      _segmentStart = 0;
      _displayedPoint = _route.first;
    }
    setState(() => _isPlaying = true);
    _playSegment();
  }

  void _playSegment() {
    if (_segmentStart >= _route.length - 1) {
      _pause();
      return;
    }
    final start = _displayedPoint ?? _route[_segmentStart];
    final end = _route[_segmentStart + 1];
    _segmentAnimation = _LatLngTween(begin: start, end: end).animate(
      // Linear: constant-speed travel between fixes, matching the live map's
      // marker-glide behavior so chained segments don't stutter.
      CurvedAnimation(parent: _segmentController, curve: Curves.linear),
    );
    _segmentController
      ..duration = _segmentDuration(_segmentStart)
      ..forward(from: 0);
  }

  Duration _segmentDuration(int index) {
    final meters = index < _segmentMeters.length ? _segmentMeters[index] : 0.0;
    final ms = (meters / _paceMetersPerSecond * 1000).clamp(
      _minSegmentMs,
      _maxSegmentMs,
    );
    return Duration(milliseconds: (ms / (_playbackSpeed * _baseSpeed)).round());
  }

  void _handleSegmentTick() {
    final animated = _segmentAnimation?.value;
    if (animated == null || !mounted) return;
    setState(() => _displayedPoint = animated);
    _mapController.move(animated, _mapController.camera.zoom);
  }

  void _handleSegmentStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _segmentStart++;
    _displayedPoint = _route[_segmentStart];
    if (_isPlaying) {
      _playSegment();
    }
  }

  void _pause() {
    _segmentController.stop();
    if (mounted) setState(() => _isPlaying = false);
  }

  void _seek(double value) {
    _pause();
    final index = value.round();
    setState(() {
      _segmentStart = index;
      _displayedPoint = _route[index];
    });
    _mapController.move(_route[index], _mapController.camera.zoom);
  }

  void _setPlaybackSpeed(double speed) {
    setState(() => _playbackSpeed = speed);
  }

  PreferredSizeWidget _appBar(ThemeData theme) {
    final session = widget.session;
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.userName),
          Text(
            '${formatLongDay(session.startAt.toLocal())} · '
            '${formatClock(session.startAt)} – ${formatClock(session.endAt)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final points = widget.session.points;

    if (points.isEmpty) {
      return Scaffold(
        appBar: _appBar(theme),
        body: const Center(child: Text('No points to replay')),
      );
    }

    final current = points[_segmentStart];
    final currentPoint = _displayedPoint ?? _route[_segmentStart];

    return Scaffold(
      appBar: _appBar(theme),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _route.first,
                    initialZoom: 15,
                    // Start on the whole trip, not just its first point.
                    initialCameraFit: _route.length > 1
                        ? CameraFit.coordinates(
                            coordinates: _route,
                            padding: const EdgeInsets.all(56),
                            maxZoom: 17,
                          )
                        : null,
                  ),
                  children: [
                    ...buildMapTileLayers(_selectedLayer),
                    PolylineLayer(
                      polylines: [
                        // A dark edge keeps the route readable on any tiles, as on the web.
                        Polyline(
                          points: _route,
                          strokeWidth: 8,
                          color: Colors.black.withValues(alpha: 0.35),
                        ),
                        ..._speedPolylines,
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _route.first,
                          width: 18,
                          height: 18,
                          child: const _RouteEndpoint(color: Color(0xFF34C759)),
                        ),
                        Marker(
                          point: _route.last,
                          width: 18,
                          height: 18,
                          child: const _RouteEndpoint(color: Color(0xFFFF453A)),
                        ),
                        Marker(
                          point: currentPoint,
                          width: TrackedUserMarker.width,
                          height: TrackedUserMarker.height,
                          child: TrackedUserMarker(
                            userId: widget.userId,
                            name: widget.userName,
                            speedKmh: current.speed * 3.6,
                            isMoving: current.isMoving,
                            heading: current.heading,
                            tooltipMessage: widget.userName,
                            beamColor: const Color(0xFF0985FB),
                            ringColor: Colors.white,
                            badgeColor: Colors.grey.shade900,
                            // Smaller than a live peer so the route stays in view.
                            compact: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: 16,
                  right: 16,
                  child: MapControlGroup(
                    children: [
                      MapLayerButton(
                        selectedLayer: _selectedLayer,
                        onLayerSelected: (layer) =>
                            setState(() => _selectedLayer = layer),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: theme.colorScheme.surfaceContainerLow,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          formatClock(current.timestamp),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${(current.speed * 3.6).toStringAsFixed(0)} km/h',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        overlayShape: SliderComponentShape.noOverlay,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Slider(
                          value: _segmentStart.toDouble(),
                          min: 0,
                          max: (points.length - 1).toDouble(),
                          divisions: points.length > 1 ? points.length - 1 : 1,
                          onChanged: points.length > 1 ? _seek : null,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: SegmentedButton<double>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: 1.0, label: Text('1x')),
                              ButtonSegment(value: 2.0, label: Text('2x')),
                              ButtonSegment(value: 4.0, label: Text('4x')),
                            ],
                            selected: {_playbackSpeed},
                            onSelectionChanged: (selection) =>
                                _setPlaybackSpeed(selection.first),
                          ),
                        ),
                        const SizedBox(width: 16),
                        IconButton.filled(
                          iconSize: 30,
                          style: IconButton.styleFrom(
                            fixedSize: const Size.square(56),
                          ),
                          tooltip: _isPlaying ? 'Pause' : 'Play',
                          icon: Icon(
                            _isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                          onPressed: _togglePlay,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteEndpoint extends StatelessWidget {
  const _RouteEndpoint({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
      ),
    );
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
