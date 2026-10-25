import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/constants.dart';
import '../../../core/formatters.dart';
import '../../../data/models/location_session.dart';
import '../../../data/network/mapbox_token_service.dart';
import '../../../data/models/location_model.dart';
import '../../auth/auth_provider.dart';

import 'map_layers.dart';
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
  static const _targetPlayback = Duration(seconds: 40);
  static const _baseSpeed = 1.0;
  final List<double> _speeds = const [0.5, 1.0, 2.0];

  late final List<LocationPoint> _route;
  late final List<LatLng> _latLngs;

  late final AnimationController _segmentController;
  late final MapboxTokenService _tokenService;
  String? _token;
  Timer? _tokenTimer;

  MapboxMap? _map;
  PolylineAnnotationManager? _lineManager;
  PointAnnotationManager? _pointManager;
  double _currentZoom = 15.0;
  int _mapKey = 0;

  int _segmentStart = 0;
  LatLng? _displayedPoint;
  bool _isPlaying = false;
  double _playbackSpeed = 1.0;
  MapLayer _selectedLayer = MapLayer.standard;

  Animation<LatLng>? _segmentAnimation;

  @override
  void initState() {
    super.initState();
    _route = widget.session.points;
    _latLngs = _route.map((p) => LatLng(p.latitude, p.longitude)).toList();
    _segmentController = AnimationController(vsync: this)
      ..addListener(_handleSegmentTick)
      ..addStatusListener(_handleSegmentStatus);
    _tokenService = MapboxTokenService(
      baseUrl: AppConstants.backendBaseUrl,
      getAccessToken: () => context.read<AuthProvider>().accessToken,
    );
    _refreshToken();
    _tokenTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshToken(),
    );
  }

  Future<void> _refreshToken() async {
    final token = await _tokenService.token;
    if (!mounted) return;
    if (token != _token) {
      setState(() {
        _token = token;
        _mapKey++;
      });
    }
  }

  @override
  void dispose() {
    _tokenTimer?.cancel();
    _segmentController.dispose();
    _tokenService.dispose();
    super.dispose();
  }

  Duration _segmentDuration(LocationPoint a, LocationPoint b) {
    const baseMs = 120.0;
    final meters = const Distance().as(
      LengthUnit.Meter,
      LatLng(a.latitude, a.longitude),
      LatLng(b.latitude, b.longitude),
    );
    final ms = (baseMs + math.sqrt(meters) * 8).clamp(120, 900);
    return Duration(milliseconds: (ms / (_playbackSpeed * _baseSpeed)).round());
  }

  void _playSegment() {
    if (_segmentStart >= _route.length - 1) {
      setState(() => _isPlaying = false);
      return;
    }
    final a = _route[_segmentStart];
    final b = _route[_segmentStart + 1];
    _segmentAnimation =
        _LatLngTween(
          begin: _latLngs[_segmentStart],
          end: _latLngs[_segmentStart + 1],
        ).animate(
          CurvedAnimation(parent: _segmentController, curve: Curves.linear),
        );
    _segmentController.duration = _segmentDuration(a, b);
    _segmentController.forward(from: 0);
  }

  void _handleSegmentTick() {
    final animated = _segmentAnimation?.value;
    if (animated == null || !mounted) return;
    setState(() => _displayedPoint = animated);
    _map?.setCamera(CameraOptions(
      center: Point(coordinates: Position(animated.longitude, animated.latitude)),
      zoom: _currentZoom,
    ));
    _syncPointAnnotations(animated);
  }

  void _handleSegmentStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _segmentStart++;
    if (_segmentStart < _latLngs.length) {
      _displayedPoint = _latLngs[_segmentStart];
    }
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
    _map?.setCamera(CameraOptions(
      center: Point(coordinates: Position(
            _latLngs[index].longitude,
            _latLngs[index].latitude,
          )),
      zoom: _currentZoom,
    ));
    _syncPointAnnotations(_latLngs[index]);
  }

  void _setPlaybackSpeed(double speed) {
    setState(() => _playbackSpeed = speed);
  }

  PreferredSizeWidget _appBar(ThemeData theme) {
    final session = widget.session;
    return AppBar(
      title: Text('${widget.userName} — ${formatShortDate(session.startAt)}'),
      actions: [
        PopupMenuButton<double>(
          tooltip: 'Playback speed',
          initialValue: _playbackSpeed,
          onSelected: _setPlaybackSpeed,
          itemBuilder: (_) => [
            for (final speed in _speeds)
              PopupMenuItem<double>(value: speed, child: Text('${speed}x')),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(child: Text('${_playbackSpeed}x')),
          ),
        ),
      ],
    );
  }

  void _syncLineAnnotations() {
    final manager = _lineManager;
    if (manager == null) return;
    manager.deleteAll().then((_) async {
      await manager.create(
        PolylineAnnotationOptions(
          geometry: LineString(
            coordinates: [
              for (final point in _latLngs)
                Position(point.longitude, point.latitude),
            ],
          ),
          lineColor: 0xFF0985FB,
          lineWidth: 4,
        ),
      );
      await manager.create(
        PolylineAnnotationOptions(
          geometry: LineString(
            coordinates: [
              for (final point in _latLngs)
                Position(point.longitude, point.latitude),
            ],
          ),
          lineColor: 0x59000000,
          lineWidth: 8,
        ),
      );
    });
  }

  void _syncPointAnnotations(LatLng current) {
    final manager = _pointManager;
    if (manager == null) return;
    manager.deleteAll().then((_) async {
      await manager.create(
        PointAnnotationOptions(
          geometry: Point(
            coordinates: Position(
              _latLngs.first.longitude,
              _latLngs.first.latitude,
            ),
          ),
          iconColor: 0xFF34C759,
          iconSize: 1.5,
        ),
      );
      await manager.create(
        PointAnnotationOptions(
          geometry: Point(
            coordinates: Position(
              _latLngs.last.longitude,
              _latLngs.last.latitude,
            ),
          ),
          iconColor: 0xFFFF453A,
          iconSize: 1.5,
        ),
      );
      await manager.create(
        PointAnnotationOptions(
          geometry: Point(
            coordinates: Position(current.longitude, current.latitude),
          ),
          iconColor: 0xFF0985FB,
          iconSize: 2.0,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_token != null) {
      MapboxOptions.setAccessToken(_token!);
    }

    return Scaffold(
      appBar: _appBar(theme),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                MapWidget(
                  key: ValueKey(_mapKey),
                  styleUri: _styleUri(_selectedLayer),
                  cameraOptions: CameraOptions(
                    center: Point(
                      coordinates: Position(
                        _latLngs.first.longitude,
                        _latLngs.first.latitude,
                      ),
                    ),
                    zoom: 15,
                  ),
                  onMapCreated: (map) async {
                    _map = map;
                    _lineManager = await map.annotations
                        .createPolylineAnnotationManager();
                    _pointManager = await map.annotations
                        .createPointAnnotationManager();
                    map.setCamera(CameraOptions(
                      center: Point(
                        coordinates: Position(
                          _latLngs.first.longitude,
                          _latLngs.first.latitude,
                        ),
                      ),
                      zoom: 15,
                    ));
                    _syncLineAnnotations();
                    _syncPointAnnotations(_latLngs.first);
                  },
                  onCameraChangeListener: (_) {},
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
            progress: _segmentStart.toDouble(),
            max: (_route.length - 1).toDouble(),
            onPlay: () {
              setState(() => _isPlaying = true);
              _playSegment();
            },
            onPause: _pause,
            onSeek: _seek,
            speed: _playbackSpeed,
            onSpeedChanged: _setPlaybackSpeed,
          ),
        ],
      ),
    );
  }

  String _styleUri(MapLayer style) {
    switch (style) {
      case MapLayer.satellite:
        return MapboxStyles.STANDARD_SATELLITE;
      case MapLayer.standard:
      case MapLayer.terrain:
        return MapboxStyles.STANDARD;
    }
  }
}

class _PlaybackBar extends StatelessWidget {
  const _PlaybackBar({
    required this.isPlaying,
    required this.progress,
    required this.max,
    required this.onPlay,
    required this.onPause,
    required this.onSeek,
    required this.speed,
    required this.onSpeedChanged,
  });

  final bool isPlaying;
  final double progress;
  final double max;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final ValueChanged<double> onSeek;
  final double speed;
  final ValueChanged<double> onSpeedChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(value: progress.clamp(0, max), max: max, onChanged: onSeek),
            Row(
              children: [
                IconButton(
                  onPressed: isPlaying ? onPause : onPlay,
                  icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                const Spacer(),
                Text('${speed}x'),
              ],
            ),
          ],
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
