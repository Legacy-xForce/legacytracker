import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../data/models/location_session.dart';
import 'map_layers.dart';
import 'tracked_user_marker.dart';
import 'tracking_map_layer.dart';

class SessionReplayScreen extends StatefulWidget {
  const SessionReplayScreen({
    super.key,
    required this.session,
    required this.userName,
  });

  final LocationSession session;
  final String userName;

  @override
  State<SessionReplayScreen> createState() => _SessionReplayScreenState();
}

class _SessionReplayScreenState extends State<SessionReplayScreen>
    with SingleTickerProviderStateMixin {
  // Fixed time per point-to-point glide, completely independent of the
  // distance between fixes (and therefore of the recorded real speed) — a
  // 200 km/h segment and a 10 km/h segment take exactly the same time.
  static const _baseSegmentDuration = Duration(milliseconds: 120);

  final MapController _mapController = MapController();
  late final AnimationController _segmentController;
  Animation<LatLng>? _segmentAnimation;

  MapLayer _selectedLayer = MapLayer.standard;
  double _playbackSpeed = 1.0;
  int _segmentStart = 0;
  LatLng? _displayedPoint;
  bool _isPlaying = false;

  late final List<LatLng> _route = widget.session.points
      .map((p) => LatLng(p.latitude, p.longitude))
      .toList();

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
    final ms = _baseSegmentDuration.inMilliseconds / _playbackSpeed;
    return Duration(milliseconds: ms.round());
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final points = widget.session.points;

    if (points.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text('${widget.userName} · Replay')),
        body: const Center(child: Text('No points to replay')),
      );
    }

    final current = points[_segmentStart];
    final currentPoint = _displayedPoint ?? _route[_segmentStart];

    return Scaffold(
      appBar: AppBar(title: Text('${widget.userName} · Replay')),
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
                  ),
                  children: [
                    ...buildMapTileLayers(_selectedLayer),
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _route,
                          strokeWidth: 4,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _route.first,
                          width: 14,
                          height: 14,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        Marker(
                          point: _route.last,
                          width: 14,
                          height: 14,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        Marker(
                          point: currentPoint,
                          width: TrackedUserMarker.width,
                          height: TrackedUserMarker.height,
                          child: TrackedUserMarker(
                            name: widget.userName,
                            speedKmh: current.speed * 3.6,
                            isMoving: current.isMoving,
                            heading: current.heading,
                            tooltipMessage: widget.userName,
                            beamColor: const Color(0xFF0985FB),
                            ringColor: const Color(0xFF0985FB),
                            badgeColor: Colors.teal.shade800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: 16,
                  right: 16,
                  child: MapLayerButton(
                    selectedLayer: _selectedLayer,
                    onLayerSelected: (layer) =>
                        setState(() => _selectedLayer = layer),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        _formatTime(current.timestamp),
                        style: theme.textTheme.bodySmall,
                      ),
                      const Spacer(),
                      Text(
                        '${(current.speed * 3.6).toStringAsFixed(0)} km/h',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: _segmentStart.toDouble(),
                    min: 0,
                    max: (points.length - 1).toDouble(),
                    divisions: points.length > 1 ? points.length - 1 : 1,
                    onChanged: points.length > 1 ? _seek : null,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SegmentedButton<double>(
                        segments: const [
                          ButtonSegment(value: 1.0, label: Text('1x')),
                          ButtonSegment(value: 2.0, label: Text('2x')),
                          ButtonSegment(value: 4.0, label: Text('4x')),
                        ],
                        selected: {_playbackSpeed},
                        onSelectionChanged: (selection) =>
                            _setPlaybackSpeed(selection.first),
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        iconSize: 42,
                        icon: Icon(
                          _isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                        ),
                        onPressed: _togglePlay,
                      ),
                    ],
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

String _formatTime(DateTime dt) {
  final local = dt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final ss = local.second.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}
