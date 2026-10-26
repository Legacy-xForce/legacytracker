import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:provider/provider.dart';

import '../../../core/constants.dart';
import '../../../core/formatters.dart';
import '../../../core/speed_color.dart';
import '../../../data/models/location_model.dart';
import '../../../data/models/location_session.dart';
import '../../../data/network/mapbox_token_gate.dart';
import '../../../data/network/mapbox_token_service.dart';
import '../../auth/auth_provider.dart';
import '../map_settings.dart';
import 'map_layers.dart';
import 'mapbox_map.dart';
import 'marker_icons.dart';
import 'tracking_map_layer.dart';

/// The route as Mapbox draws it: one dark casing under one coloured line per
/// run of similar speed, exactly like the web replay layer. The casing is
/// opaque black at 0.35 rather than a translucent black colour, so if the
/// layers ever land in the wrong order the route is tinted, not replaced.
List<MapPolyline> buildSpeedRoute({
  required List<LatLng> points,
  required List<double> speedsMps,
}) {
  if (points.length < 2) return const [];
  double speedAt(int index) => index < speedsMps.length ? speedsMps[index] : 0;
  final lines = <MapPolyline>[
    MapPolyline(
      id: 'route-casing',
      points: points,
      color: const Color(0xFF000000),
      opacity: 0.35,
      width: 8,
      layer: MapPolylineLayer.casing,
    ),
  ];
  var run = <LatLng>[points.first];
  Color? runColor;
  var runIndex = 0;
  void closeRun() {
    if (run.length < 2 || runColor == null) return;
    lines.add(
      MapPolyline(
        id: 'route-$runIndex',
        points: List.of(run),
        color: runColor,
        width: 5,
        layer: MapPolylineLayer.route,
      ),
    );
    runIndex++;
  }

  for (var i = 1; i < points.length; i++) {
    final color = speedColor((speedAt(i - 1) + speedAt(i)) / 2);
    if (runColor == null) {
      runColor = color;
    } else if (color != runColor) {
      closeRun();
      run = <LatLng>[run.last];
      runColor = color;
    }
    run.add(points[i]);
  }
  closeRun();
  return lines;
}

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
  // each glide lasts in proportion to the distance it covers.
  static const _targetPlayback = Duration(seconds: 40);
  static const _baseSpeed = 2.0;
  static const _minPaceMetersPerSecond = 5.0;
  static const _minSegmentMs = 16.0;
  static const _maxSegmentMs = 3000.0;

  final MarkerIconFactory _icons = MarkerIconFactory();
  final Map<String, MarkerImage> _images = {};
  final Set<String> _pendingImages = {};

  /// Bumped whenever the icon factory rebuilds, so a render that was already in
  /// flight with the older bitmaps cannot write itself back into the cache.
  int _iconEpoch = 0;

  late final List<LocationPoint> _route;
  late final List<LatLng> _latLngs;
  late final List<double> _segmentMeters;
  late final double _paceMetersPerSecond;

  late final AnimationController _segmentController;
  late final MapboxTokenService _tokenService;
  late MapLayer _selectedLayer;

  MapboxMap? _map;
  double _currentZoom = 15;
  double _playbackSpeed = 1.0;
  int _segmentStart = 0;
  LatLng? _displayedPoint;
  bool _isPlaying = false;
  bool _initialized = false;
  DateTime? _lastTick;

  /// The route and the moving marker. Playback updates this ~20x a second, so
  /// it lives here rather than in the widget tree.
  final MapScene _scene = MapScene();
  String? _sceneSpec;

  @override
  void initState() {
    super.initState();
    _route = widget.session.points;
    _latLngs = [
      for (final point in _route) LatLng(point.latitude, point.longitude),
    ];
    _segmentMeters = [
      for (var i = 1; i < _latLngs.length; i++)
        const Distance().as(LengthUnit.Meter, _latLngs[i - 1], _latLngs[i]),
    ];
    _paceMetersPerSecond = math.max(
      _segmentMeters.fold<double>(0, (sum, meters) => sum + meters) /
          _targetPlayback.inSeconds,
      _minPaceMetersPerSecond,
    );
    _scene.polylines = _buildRouteLines();
    _segmentController = AnimationController(vsync: this)
      ..addListener(_handleSegmentTick)
      ..addStatusListener(_handleSegmentStatus);
    _displayedPoint = _latLngs.isNotEmpty ? _latLngs.first : null;
    _icons.addListener(_handleIconsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _tokenService = MapboxTokenService(
      baseUrl: AppConstants.backendBaseUrl,
      getAccessToken: () => context.read<AuthProvider>().accessToken,
    );
    _selectedLayer = context.read<MapSettings>().defaultLayer;
    _initialized = true;
  }

  @override
  void dispose() {
    _icons
      ..removeListener(_handleIconsChanged)
      ..dispose();
    _scene.dispose();
    _segmentController.dispose();
    _tokenService.dispose();
    super.dispose();
  }

  /// The route plus the moving marker (and its beam and endpoints). Positions
  /// and speed change continuously, so they go through the scene.
  void _syncScene() {
    if (_latLngs.isEmpty) return;
    final index = _segmentStart.clamp(0, _route.length - 1);
    final current = _route[index];
    final currentPoint = _displayedPoint ?? _latLngs[index];
    final moving = current.isMoving;
    final speedKmh = current.speed * 3.6;
    final speedBucket = moving ? (speedKmh / 5).round() * 5 : -1;
    final heading = current.heading;
    final showBeam = moving && heading != null && heading.isFinite;

    final markerImage = _imageFor(
      'replay:${widget.userId}:$speedBucket',
      () => _icons.personMarker(
        MarkerPerson(
          id: widget.userId,
          name: widget.userName,
          isMoving: moving,
          speedKmh: speedKmh,
        ),
      ),
    );
    final beamImage = showBeam
        ? _imageFor('beam', () => _icons.headingBeam(markerAccentColor))
        : null;
    final startImage = _imageFor(
      'start',
      () => _icons.endpointMarker(const Color(0xFF34C759)),
    );
    final endImage = _imageFor(
      'end',
      () => _icons.endpointMarker(const Color(0xFFFF453A)),
    );

    final markers = <MapMarker>[
      if (beamImage != null)
        MapMarker(
          id: 'moving-beam',
          position: currentPoint,
          image: beamImage,
          layer: MapMarkerLayer.beam,
          rotation: heading!,
        ),
      if (startImage != null)
        MapMarker(
          id: 'route-start',
          position: _latLngs.first,
          image: startImage,
          layer: MapMarkerLayer.base,
        ),
      if (endImage != null)
        MapMarker(
          id: 'route-end',
          position: _latLngs.last,
          image: endImage,
          layer: MapMarkerLayer.base,
        ),
      if (markerImage != null)
        MapMarker(
          id: 'replay-marker',
          position: currentPoint,
          image: markerImage,
          layer: MapMarkerLayer.user,
          // The web draws the replay rider at 70% so the route stays in view.
          iconSize: 0.7,
        ),
    ];

    final spec = [
      for (final marker in markers)
        '${marker.id}@${marker.position.latitude},${marker.position.longitude}'
            ',${marker.image.id},${marker.rotation}',
    ].join('|');
    if (spec == _sceneSpec) return;
    _sceneSpec = spec;
    _scene.markers = markers;
    _scene.markChanged();
  }

  void _handleIconsChanged() {
    if (!mounted) return;
    _images.clear();
    _pendingImages.clear();
    _iconEpoch++;
    _syncScene();
  }

  List<MapPolyline> _buildRouteLines() => buildSpeedRoute(
    points: _latLngs,
    speedsMps: [for (final point in _route) point.speed],
  );

  Duration _segmentDuration(int index) {
    final meters = index < _segmentMeters.length ? _segmentMeters[index] : 0.0;
    final ms = (meters / _paceMetersPerSecond * 1000).clamp(
      _minSegmentMs,
      _maxSegmentMs,
    );
    return Duration(milliseconds: (ms / (_playbackSpeed * _baseSpeed)).round());
  }

  void _togglePlay() {
    if (_route.length < 2) return;
    if (_isPlaying) {
      _pause();
    } else {
      _play();
    }
  }

  void _play() {
    if (_route.length < 2) return;
    if (_segmentStart >= _route.length - 1) {
      _segmentStart = 0;
      _displayedPoint = _latLngs.first;
    }
    setState(() => _isPlaying = true);
    _playSegment();
  }

  void _playSegment() {
    if (_segmentStart >= _latLngs.length - 1) {
      _pause();
      return;
    }
    final start = _displayedPoint ?? _latLngs[_segmentStart];
    final end = _latLngs[_segmentStart + 1];
    _segmentController
      ..stop()
      ..duration = _segmentDuration(_segmentStart)
      ..forward(from: 0);
    _segmentAnimation = _LatLngTween(begin: start, end: end).animate(
      CurvedAnimation(parent: _segmentController, curve: Curves.linear),
    );
  }

  Animation<LatLng>? _segmentAnimation;

  void _handleSegmentTick() {
    final animated = _segmentAnimation?.value;
    if (animated == null || !mounted) return;
    final now = DateTime.now();
    final last = _lastTick;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 50)) {
      return;
    }
    _lastTick = now;
    _displayedPoint = animated;
    // The route and the marker live in the scene, so playback does not rebuild
    // the screen 20 times a second.
    _syncScene();
    _map?.setCamera(
      CameraOptions(
        center: Point(
          coordinates: Position(animated.longitude, animated.latitude),
        ),
        zoom: _currentZoom,
      ),
    );
  }

  void _handleSegmentStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _segmentStart++;
    if (_segmentStart < _latLngs.length) {
      _displayedPoint = _latLngs[_segmentStart];
    }
    // The clock and speed read-out follow the segment, so this refreshes once
    // per segment rather than once per frame.
    if (mounted) setState(() {});
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
    final index = value.round().clamp(0, _latLngs.length - 1);
    setState(() {
      _segmentStart = index;
      _displayedPoint = _latLngs[index];
    });
    _syncScene();
    _centerOn(_latLngs[index]);
  }

  void _centerOn(LatLng point) {
    _map?.setCamera(
      CameraOptions(
        center: Point(coordinates: Position(point.longitude, point.latitude)),
        zoom: _currentZoom,
      ),
    );
  }

  void _setPlaybackSpeed(double speed) {
    setState(() => _playbackSpeed = speed);
  }

  void _onCameraChanged(CameraState state) {
    _currentZoom = state.zoom;
  }

  Future<void> _fitRoute(MapboxMap map) async {
    if (_latLngs.isEmpty) return;
    if (_segmentStart > 0 || _isPlaying) {
      _centerOn(_displayedPoint ?? _latLngs.first);
      return;
    }
    if (_latLngs.length == 1) {
      map.setCamera(
        CameraOptions(
          center: Point(
            coordinates: Position(
              _latLngs.first.longitude,
              _latLngs.first.latitude,
            ),
          ),
          zoom: _currentZoom,
        ),
      );
      return;
    }
    final camera = await map.cameraForCoordinatesPadding(
      [
        for (final point in _latLngs)
          Point(coordinates: Position(point.longitude, point.latitude)),
      ],
      CameraOptions(),
      MbxEdgeInsets(top: 56, left: 56, bottom: 56, right: 56),
      null,
      null,
    );
    if (!mounted) return;
    if (camera.zoom != null) _currentZoom = camera.zoom!;
    map.setCamera(camera);
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
              // was in flight, so its bitmap is the pre-avatar one: dropping it
              // here is what stops the initial-letter marker sticking for good.
              if (!mounted || epoch != _iconEpoch) return;
              _images[key] = image;
              _syncScene();
            })
            .catchError((_) {
              _pendingImages.remove(key);
            }),
      );
    }
    return null;
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
    if (_route.isEmpty) {
      return Scaffold(
        appBar: _appBar(theme),
        body: const Center(child: Text('No points to replay')),
      );
    }

    _syncScene();
    final currentIndex = _segmentStart.clamp(0, _route.length - 1);
    final current = _route[currentIndex];
    final speedKmh = current.speed * 3.6;

    return Scaffold(
      appBar: _appBar(theme),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                MapboxTokenGate(
                  service: _tokenService,
                  builder: (context, session) => MapboxMapWidget(
                    key: ValueKey('replay-map-${session.generation}'),
                    accessToken: session.token,
                    initialCenter: _latLngs.first,
                    initialZoom: _currentZoom,
                    style: _selectedLayer,
                    darkMode: theme.brightness == Brightness.dark,
                    scene: _scene,
                    onCameraChanged: _onCameraChanged,
                    onLoadError: (_) => session.recover(),
                    onMapCreated: (map) {
                      _map = map;
                      unawaited(_fitRoute(map));
                    },
                  ),
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
          _PlaybackBar(
            isPlaying: _isPlaying,
            progress: currentIndex.toDouble(),
            max: math.max(1, _route.length - 1).toDouble(),
            divisions: math.max(1, _route.length - 1),
            currentTime: formatClock(current.timestamp),
            speedKmh: speedKmh,
            speed: _playbackSpeed,
            onPlay: _route.length > 1 ? _togglePlay : null,
            onSeek: _route.length > 1 ? _seek : (_) {},
            onSpeedChanged: _setPlaybackSpeed,
          ),
        ],
      ),
    );
  }
}

class _PlaybackBar extends StatelessWidget {
  const _PlaybackBar({
    required this.isPlaying,
    required this.progress,
    required this.max,
    required this.divisions,
    required this.currentTime,
    required this.speedKmh,
    required this.speed,
    required this.onPlay,
    required this.onSeek,
    required this.onSpeedChanged,
  });

  final bool isPlaying;
  final double progress;
  final double max;
  final int divisions;
  final String currentTime;
  final double speedKmh;
  final double speed;
  final VoidCallback? onPlay;
  final ValueChanged<double> onSeek;
  final ValueChanged<double> onSpeedChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
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
                    currentTime,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${speedKmh.toStringAsFixed(0)} km/h',
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
                    value: progress.clamp(0, max),
                    min: 0,
                    max: max,
                    divisions: divisions,
                    onChanged: onSeek,
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
                      selected: {speed},
                      onSelectionChanged: (selection) =>
                          onSpeedChanged(selection.first),
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton.filled(
                    iconSize: 30,
                    style: IconButton.styleFrom(
                      fixedSize: const Size.square(56),
                    ),
                    tooltip: isPlaying ? 'Pause' : 'Play',
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    onPressed: onPlay,
                  ),
                ],
              ),
            ],
          ),
        ),
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
