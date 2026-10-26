// Standalone spike harness for the Mapbox phone map. No login or backend is
// needed: pass a development token on the command line.
//
//   flutter run -t lib/main_mapcheck.dart -d <device> \
//     --dart-define=MAPBOX_TOKEN=pk.…
//
// Optionally pass a second token to exercise runtime replacement:
//
//   --dart-define=MAPBOX_TOKEN_ALT=pk.…
//
// The status panel records how many times a style loaded. "Apply token in
// place" sets the global token and reloads the style WITHOUT recreating the
// MapWidget; a rising style count proves the already-created map accepts the
// new token. "Recreate map" is the fallback path.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import 'src/features/tracking/widgets/map_geometry.dart';
import 'src/features/tracking/widgets/mapbox_map.dart';
import 'src/features/tracking/widgets/marker_icons.dart';
import 'src/features/tracking/widgets/tracking_map_layer.dart';

void main() => runApp(const _MapCheckApp());

class _MapCheckApp extends StatelessWidget {
  const _MapCheckApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mapbox map spike',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: const _MapCheckScreen(),
    );
  }
}

class _Peer {
  _Peer({
    required this.id,
    required this.name,
    required this.position,
    this.heading = 0,
    this.moving = false,
    this.stale = false,
  });

  final String id;
  final String name;
  LatLng position;
  double heading;
  bool moving;
  bool stale;
}

class _MapCheckScreen extends StatefulWidget {
  const _MapCheckScreen();

  @override
  State<_MapCheckScreen> createState() => _MapCheckScreenState();
}

class _MapCheckScreenState extends State<_MapCheckScreen> {
  static const _start = LatLng(45.07031, 7.68688); // Piazza Castello, Turin
  static const _token = String.fromEnvironment('MAPBOX_TOKEN');
  static const _altToken = String.fromEnvironment('MAPBOX_TOKEN_ALT');

  final MarkerIconFactory _icons = MarkerIconFactory();
  final Map<String, MarkerImage> _images = {};
  final Set<String> _pendingImages = {};

  Timer? _timer;
  int _tick = 0;
  int _mapKey = 0;
  int _styleLoads = 0;
  String? _loadError;
  String _status = 'Ready';
  String _activeToken = _token;
  MapLayer _layer = MapLayer.standard;
  MapboxMap? _map;
  double _zoom = 14;

  late final List<_Peer> _peers;

  @override
  void initState() {
    super.initState();
    _icons.addListener(_handleIconsChanged);
    _peers = [
      _Peer(
        id: 'peer-near',
        name: 'Near',
        position: const LatLng(45.07060, 7.68720),
        heading: 45,
        moving: true,
      ),
      _Peer(
        id: 'peer-far',
        name: 'Far',
        position: const LatLng(45.07600, 7.69500),
        heading: 130,
        moving: true,
      ),
      _Peer(
        id: 'peer-stale',
        name: 'Stale',
        position: const LatLng(45.06600, 7.68000),
        heading: 270,
        stale: true,
      ),
      _Peer(
        id: 'peer-cluster-a',
        name: 'Ada',
        position: const LatLng(45.07045, 7.68710),
        heading: 20,
        moving: true,
      ),
      _Peer(
        id: 'peer-cluster-b',
        name: 'Bo',
        position: const LatLng(45.07038, 7.68702),
        heading: 200,
        moving: true,
      ),
      _Peer(
        id: 'peer-cluster-c',
        name: 'Cy',
        position: const LatLng(45.07052, 7.68718),
        heading: 90,
        moving: true,
      ),
      _Peer(
        id: 'peer-cluster-d',
        name: 'Di',
        position: const LatLng(45.07030, 7.68695),
        heading: 310,
        moving: true,
      ),
    ];
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _tick++;
      final phase = _tick * 0.08;
      setState(() {
        for (var i = 0; i < _peers.length; i++) {
          final peer = _peers[i];
          if (peer.stale) continue;
          final angle = phase + i * 0.9;
          peer.position = LatLng(
            peer.position.latitude + math.sin(angle) * 0.000012,
            peer.position.longitude + math.cos(angle) * 0.000016,
          );
          peer.heading = (angle * 180 / math.pi) % 360;
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _icons
      ..removeListener(_handleIconsChanged)
      ..dispose();
    super.dispose();
  }

  void _handleIconsChanged() {
    if (!mounted) return;
    setState(() => _images.clear());
  }

  String _styleUri(MapLayer layer) => switch (layer) {
    MapLayer.satellite => MapboxStyles.STANDARD_SATELLITE,
    MapLayer.standard => MapboxStyles.STANDARD,
  };

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

  List<MapMarker> _buildMarkers() {
    final entries = <ClusterInput<_Peer>>[
      ClusterInput(
        value: _Peer(
          id: 'self',
          name: 'Me',
          position: _start,
          heading: 180,
          moving: true,
        ),
        point: _start,
      ),
      for (final peer in _peers)
        ClusterInput(value: peer, point: peer.position),
    ];
    final groups = clusterMarkers(entries, zoom: _zoom);
    final markers = <MapMarker>[];
    for (final group in groups) {
      final persons = <MarkerPerson>[
        for (final member in group.members)
          MarkerPerson(
            id: member.value.id,
            name: member.value.name,
            isStale: member.value.stale,
          ),
      ];
      final signature = [
        for (final person in persons)
          '${person.id}|${person.name}|${person.isStale}|'
              '${identityHashCode(person.avatarBytes)}',
      ].join(',');
      final image = _imageFor(
        'live:$signature',
        () => _icons.liveMarker(persons),
      );
      if (image == null) continue;
      final single = group.members.length == 1;
      markers.add(
        MapMarker(
          id: single
              ? 'user-${group.members.first.value.id}'
              : 'cluster-${group.members.length}-${group.members.first.value.id}',
          position: single ? group.members.first.point : group.center,
          image: image,
          layer: single ? MapMarkerLayer.user : MapMarkerLayer.cluster,
        ),
      );
    }
    return markers;
  }

  void _applyTokenInPlace() {
    final token = _altToken.isNotEmpty && _activeToken != _altToken
        ? _altToken
        : _activeToken;
    if (token.isEmpty) return;
    setState(() {
      _activeToken = token;
      _status = 'Applying token ${_shortToken(token)} in place…';
    });
    MapboxOptions.setAccessToken(token);
    // Force new resource requests on the existing map. If the style loads,
    // the already-created map accepted the runtime token.
    _map?.loadStyleURI(_styleUri(_layer));
  }

  String _shortToken(String token) =>
      token.length <= 10 ? token : '${token.substring(0, 10)}…';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_token.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mapbox map spike')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.key_off_rounded, size: 40),
              const SizedBox(height: 12),
              Text('No Mapbox token', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                'flutter run -t lib/main_mapcheck.dart -d <device> '
                '--dart-define=MAPBOX_TOKEN=pk.…',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final markers = _buildMarkers();
    return Scaffold(
      body: Stack(
        children: [
          MapboxMapWidget(
            key: ValueKey('spike-map-$_mapKey'),
            accessToken: _activeToken,
            initialCenter: _start,
            initialZoom: _zoom,
            style: _layer,
            darkMode: theme.brightness == Brightness.dark,
            markers: markers,
            checkpoints: const [
              MapCheckpointOverlay(
                id: 'home',
                center: _start,
                radiusMeters: 120,
                label: 'Home',
              ),
            ],
            showCheckpointLabels: true,
            onMapCreated: (map) {
              _map = map;
              map.setCamera(
                CameraOptions(
                  center: Point(
                    coordinates: Position(_start.longitude, _start.latitude),
                  ),
                  zoom: _zoom,
                ),
              );
            },
            onCameraChanged: (state) => _zoom = state.zoom,
            onStyleLoaded: () {
              setState(() {
                _styleLoads++;
                _loadError = null;
                _status = 'Style loaded with ${_shortToken(_activeToken)}';
              });
            },
            onLoadError: (error) {
              setState(() {
                _loadError = '${error.type}: ${error.message}';
                _status = 'Map load error';
              });
            },
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: SafeArea(
              child: _SpikeStatus(
                token: _activeToken,
                altToken: _altToken,
                styleLoads: _styleLoads,
                status: _status,
                loadError: _loadError,
                layer: _layer,
                onApplyToken: _applyTokenInPlace,
                onRecreate: () => setState(() {
                  _mapKey++;
                  _status = 'Map recreated with ${_shortToken(_activeToken)}';
                }),
                onToggleStyle: () => setState(() {
                  _layer = _layer == MapLayer.standard
                      ? MapLayer.satellite
                      : MapLayer.standard;
                  _status = 'Loading ${_layer.name}…';
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpikeStatus extends StatelessWidget {
  const _SpikeStatus({
    required this.token,
    required this.altToken,
    required this.styleLoads,
    required this.status,
    required this.loadError,
    required this.layer,
    required this.onApplyToken,
    required this.onRecreate,
    required this.onToggleStyle,
  });

  final String token;
  final String altToken;
  final int styleLoads;
  final String status;
  final String? loadError;
  final MapLayer layer;
  final VoidCallback onApplyToken;
  final VoidCallback onRecreate;
  final VoidCallback onToggleStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'token ${token.isEmpty ? '—' : token.substring(0, math.min(10, token.length))}…'
              ' · style loads $styleLoads'
              ' · ${layer.name}',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 2),
            Text(status, style: theme.textTheme.bodySmall),
            if (loadError != null)
              Text(
                loadError!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonal(
                  onPressed: onApplyToken,
                  child: Text(
                    altToken.isEmpty || altToken == token
                        ? 'Re-apply token in place'
                        : 'Switch token in place',
                  ),
                ),
                OutlinedButton(
                  onPressed: onRecreate,
                  child: const Text('Recreate map'),
                ),
                OutlinedButton(
                  onPressed: onToggleStyle,
                  child: Text(
                    layer == MapLayer.standard ? 'Satellite' : 'Standard',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
