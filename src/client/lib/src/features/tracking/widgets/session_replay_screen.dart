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
import '../map_variant.dart';
import 'map_layers.dart';
import 'mapbox_map.dart';
import 'marker_icons.dart';
import 'tracking_map_layer.dart';
import '../../../core/palette.dart';

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
      color: AppPalette.black,
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

/// One point on the replay clock: which recorded fix was last passed, where
/// the marker is between it and the next, and which way it is facing.
class ReplayFix {
  const ReplayFix({
    required this.index,
    required this.point,
    this.heading,
  });

  final int index;
  final LatLng point;

  /// Interpolated between the two fixes' headings, shortest arc; null when
  /// neither has one.
  final double? heading;
}

/// Timing for a replay route, the web's `ReplayTrack` in miniature: the pace
/// is a constant on-screen speed, so the whole trip covers roughly
/// [targetPlayback] whatever it was recorded at, and each fix is reached at
/// a known time. One clock drives the marker - dense fixes are passed
/// continuously through [positionAt] instead of each playing as its own
/// minimum-length animation, which is what made the old step-by-step player
/// teleport through turns and stops.
class ReplayTrack {
  ReplayTrack(
    List<LatLng> latLngs, {
    List<double?> headings = const [],
    Duration targetPlayback = const Duration(seconds: 40),
    double minPaceMetersPerSecond = 5.0,
    double minSegmentMs = 16.0,
    double maxSegmentMs = 3000.0,
  }) {
    _headings = headings.length == latLngs.length ? headings : const [];
    if (latLngs.length < 2) {
      _starts = const [0];
      return;
    }
    final distance = const Distance();
    final meters = [
      for (var i = 1; i < latLngs.length; i++)
        distance.as(LengthUnit.Meter, latLngs[i - 1], latLngs[i]),
    ];
    final total = meters.fold<double>(0, (sum, m) => sum + m);
    final pace = math.max(
      total / targetPlayback.inSeconds,
      minPaceMetersPerSecond,
    );
    final starts = <double>[0];
    for (final m in meters) {
      final ms = (m / pace * 1000).clamp(minSegmentMs, maxSegmentMs);
      starts.add(starts.last + ms);
    }
    _starts = starts;
  }

  /// Playback time in ms (at 1x) at which each fix is reached.
  late final List<double> _starts;

  /// The route's recorded headings, aligned with the fixes; empty when the
  /// route was built without them.
  late final List<double?> _headings;

  /// Total playback time at 1x pace, in ms.
  double get durationMs => _starts.last;

  /// The whole trip as one 1x duration.
  Duration get duration => Duration(milliseconds: durationMs.round());

  /// Where the marker is `elapsed` ms into playback (1x scale), interpolating
  /// linearly between fixes like the web's `positionAt`. The heading sweeps
  /// the short way round between fixes, so the beam turns through a corner
  /// instead of snapping at each one.
  ReplayFix positionAt(List<LatLng> latLngs, double elapsed) {
    if (latLngs.isEmpty) return const ReplayFix(index: 0, point: LatLng(0, 0));
    final last = latLngs.length - 1;
    if (elapsed <= 0) {
      return ReplayFix(index: 0, point: latLngs.first, heading: _heading(0));
    }
    if (elapsed >= durationMs || last == 0) {
      return ReplayFix(
        index: last,
        point: latLngs[last],
        heading: _heading(last),
      );
    }
    // Binary search for the segment containing `elapsed`.
    var low = 0;
    var high = last - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_starts[mid] <= elapsed) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    final a = latLngs[low];
    final b = latLngs[low + 1];
    final span = _starts[low + 1] - _starts[low];
    final t = span > 0 ? (elapsed - _starts[low]) / span : 1.0;
    return ReplayFix(
      index: low,
      point: LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      ),
      heading: _lerpHeading(_heading(low), _heading(low + 1), t),
    );
  }

  /// The fix at [fraction] of the trip (0..1), for seeking.
  ReplayFix positionAtFraction(List<LatLng> latLngs, double fraction) =>
      positionAt(latLngs, fraction.clamp(0.0, 1.0) * durationMs);

  double? _heading(int index) {
    if (_headings.isEmpty || index >= _headings.length) return null;
    final value = _headings[index];
    return value != null && value.isFinite ? value : null;
  }

  static double? _lerpHeading(double? from, double? to, double t) {
    if (from == null) return to;
    if (to == null) return from;
    // Shortest arc, so 350° -> 10° turns through north, not all the way back.
    final delta = (to - from + 540) % 360 - 180;
    return (from + delta * t + 360) % 360;
  }
}

class _SessionReplayScreenState extends State<SessionReplayScreen>
    with SingleTickerProviderStateMixin {
  // Constant on-screen speed, independent of the recorded real speed; the
  // per-fix timings live in [ReplayTrack].
  static const _baseSpeed = 2.0;

  final MarkerIconFactory _icons = MarkerIconFactory();
  final Map<String, MarkerImage> _images = {};
  final Set<String> _pendingImages = {};

  /// Bumped whenever the icon factory rebuilds, so a render that was already in
  /// flight with the older bitmaps cannot write itself back into the cache.
  int _iconEpoch = 0;

  late final List<LocationPoint> _route;
  late final List<LatLng> _latLngs;
  late final ReplayTrack _track;

  late final AnimationController _playController;
  late final MapboxTokenService _tokenService;
  late MapLayer _selectedLayer;

  MapboxMap? _map;
  double _currentZoom = 15;
  double _playbackSpeed = 1.0;
  int _currentIndex = 0;
  LatLng? _displayedPoint;

  /// The interpolated heading under the playhead, for the beam.
  double? _displayedHeading;
  bool _isPlaying = false;
  bool _initialized = false;

  /// The clock and speed text, refreshed only when the displayed value
  /// changes, so a dense stretch of fixes cannot rebuild the screen per
  /// frame.
  String _clockText = '';
  String _speedText = '';

  /// The route and the moving marker. Playback updates this per frame, so
  /// it lives here rather than in the widget tree.
  final MapScene _scene = MapScene();
  String? _sceneSpec;

  /// The rider's last rendered bitmap, kept across speed-bucket changes so
  /// the marker never has a frame without one.
  MarkerImage? _lastRiderImage;

  @override
  void initState() {
    super.initState();
    _route = widget.session.points;
    _latLngs = [
      for (final point in _route) LatLng(point.latitude, point.longitude),
    ];
    _track = ReplayTrack(
      _latLngs,
      headings: [for (final point in _route) point.heading],
    );
    _scene.polylines = _buildRouteLines();
    _playController = AnimationController(vsync: this, duration: _track.duration)
      ..addListener(_handleTick)
      ..addStatusListener(_handleStatus);
    _displayedPoint = _latLngs.isNotEmpty ? _latLngs.first : null;
    _displayedHeading = _route.isNotEmpty ? _route.first.heading : null;
    _syncReadout();
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
    _playController.dispose();
    _tokenService.dispose();
    super.dispose();
  }

  /// The route plus the moving marker (and its beam and endpoints). Positions
  /// and speed change continuously, so they go through the scene.
  void _syncScene() {
    if (_latLngs.isEmpty) return;
    final index = _currentIndex.clamp(0, _route.length - 1);
    final current = _route[index];
    final currentPoint = _displayedPoint ?? _latLngs[index];
    final moving = current.isMoving;
    final speedKmh = current.speed * 3.6;
    final speedBucket = moving ? (speedKmh / 5).round() * 5 : -1;
    final heading = _displayedHeading ?? current.heading;
    final showBeam = moving && heading != null && heading.isFinite;

    final colors = MarkerColors.from(Theme.of(context).colorScheme);
    final riderImage = _imageFor(
      'replay:${widget.userId}:${colors.id}:$speedBucket',
      () => _icons.personMarker(
        MarkerPerson(
          id: widget.userId,
          name: widget.userName,
          isMoving: moving,
          speedKmh: speedKmh,
        ),
        colors: colors,
      ),
    );
    if (riderImage != null) _lastRiderImage = riderImage;
    // A new speed bucket renders asynchronously; keep the previous bitmap on
    // screen until the new one lands, or the avatar blinks out for a frame
    // at every bucket change - which is what made playback flicker.
    final markerImage = _lastRiderImage;
    final beamImage = showBeam
        ? _imageFor(
            'beam:${colors.accent.toARGB32()}',
            () => _icons.headingBeam(colors.accent),
          )
        : null;
    final startImage = _imageFor(
      'start',
      () => _icons.endpointMarker(AppPalette.online),
    );
    final endImage = _imageFor(
      'end',
      () => _icons.endpointMarker(AppPalette.arrival),
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
    if (_playController.isCompleted) {
      _playController.value = 0;
      _currentIndex = 0;
      _displayedPoint = _latLngs.first;
      _displayedHeading = _route.first.heading;
      _syncReadout();
    }
    setState(() => _isPlaying = true);
    _applySpeed();
    _playController.forward();
  }

  /// The wall-clock duration for the current speed option. The controller's
  /// value is always the trip fraction, so changing speed mid-playback keeps
  /// the playhead where it is and only alters the rate.
  void _applySpeed() {
    _playController.duration = Duration(
      milliseconds:
          (_track.durationMs / (_playbackSpeed * _baseSpeed))
              .round()
              .clamp(1, 1 << 31),
    );
  }

  void _handleTick() {
    if (!mounted || _latLngs.isEmpty) return;
    // One update per animation frame: the marker and the camera move together
    // every frame, which is what makes the glide read as smooth. The old
    // 50 ms throttle here was the other half of the jank - 20 fps steps
    // against a 60-120 Hz screen.
    final fix = _track.positionAt(
      _latLngs,
      _playController.value * _track.durationMs,
    );
    _displayedPoint = fix.point;
    _displayedHeading = fix.heading;
    final moved = fix.index != _currentIndex;
    if (moved) _currentIndex = fix.index;
    // The route and the marker live in the scene, so playback does not rebuild
    // the screen per frame.
    _syncScene();
    _map?.setCamera(
      CameraOptions(
        center: Point(
          coordinates: Position(fix.point.longitude, fix.point.latitude),
        ),
        zoom: _currentZoom,
      ),
    );
    if (moved) _syncReadout();
  }

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _currentIndex = _latLngs.length - 1;
    _displayedPoint = _latLngs.last;
    _displayedHeading = _route.last.heading;
    _syncScene();
    _syncReadout();
    if (mounted) setState(() => _isPlaying = false);
  }

  void _pause() {
    _playController.stop();
    if (mounted) setState(() => _isPlaying = false);
  }

  void _seekFraction(double fraction) {
    _pause();
    final clamped = fraction.clamp(0.0, 1.0);
    _playController.value = clamped;
    final fix = _track.positionAtFraction(_latLngs, clamped);
    setState(() {
      _currentIndex = fix.index;
      _displayedPoint = fix.point;
      _displayedHeading = fix.heading;
    });
    _syncScene();
    _syncReadout();
    _centerOn(fix.point);
  }

  /// Refresh the clock and speed text, rebuilding only when what is displayed
  /// actually changed: during a dense stretch of fixes the index moves many
  /// times a second while the minute-resolution clock and the rounded km/h
  /// usually do not.
  void _syncReadout() {
    if (_route.isEmpty) return;
    final current = _route[_currentIndex.clamp(0, _route.length - 1)];
    final clock = formatClock(current.timestamp);
    final speed = '${(current.speed * 3.6).round()} km/h';
    if (clock == _clockText && speed == _speedText) return;
    if (mounted) {
      setState(() {
        _clockText = clock;
        _speedText = speed;
      });
    } else {
      _clockText = clock;
      _speedText = speed;
    }
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
    if (!_isPlaying) {
      _applySpeed();
      return;
    }
    // Changing `duration` on a running AnimationController does not re-rate
    // the live ticker, so 2x/4x looked selected but played at the old speed.
    // Restarting at the current fraction keeps the position and takes the new
    // rate immediately.
    final fraction = _playController.value;
    _playController.stop();
    _applySpeed();
    _playController.forward(from: fraction);
  }

  void _onCameraChanged(CameraState state) {
    _currentZoom = state.zoom;
  }

  Future<void> _fitRoute(MapboxMap map) async {
    if (_latLngs.isEmpty) return;
    if (_currentIndex > 0 || _playController.value > 0) {
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
                    lightPreset: resolveMapPreset(
                      context.watch<MapSettings>().mapVariant,
                      DateTime.now(),
                    ),
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
            position: _playController,
            currentTime: _clockText,
            speedText: _speedText,
            speed: _playbackSpeed,
            onPlay: _route.length > 1 ? _togglePlay : null,
            onSeek: _route.length > 1 ? _seekFraction : (_) {},
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
    required this.position,
    required this.currentTime,
    required this.speedText,
    required this.speed,
    required this.onPlay,
    required this.onSeek,
    required this.onSpeedChanged,
  });

  final bool isPlaying;

  /// The playhead, 0..1 across the trip. The slider listens to it directly,
  /// so playback can glide while the rest of the screen rebuilds only when
  /// the read-out changes.
  final Animation<double> position;
  final String currentTime;
  final String speedText;
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
                    speedText,
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
                  child: AnimatedBuilder(
                    animation: position,
                    builder: (context, child) => Slider(
                      value: position.value.clamp(0.0, 1.0),
                      min: 0,
                      max: 1,
                      onChanged: onSeek,
                    ),
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
