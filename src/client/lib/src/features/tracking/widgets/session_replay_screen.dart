import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../data/models/location_session.dart';

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

class _SessionReplayScreenState extends State<SessionReplayScreen> {
  static const _tickInterval = Duration(milliseconds: 400);

  final MapController _mapController = MapController();
  Timer? _ticker;
  int _index = 0;
  bool _isPlaying = false;

  late final List<LatLng> _route = widget.session.points
      .map((p) => LatLng(p.latitude, p.longitude))
      .toList();

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _togglePlay() => _isPlaying ? _pause() : _play();

  void _play() {
    if (widget.session.points.length < 2) return;
    if (_index >= widget.session.points.length - 1) {
      _index = 0;
    }
    setState(() => _isPlaying = true);
    _ticker?.cancel();
    _ticker = Timer.periodic(_tickInterval, (_) {
      if (_index >= widget.session.points.length - 1) {
        _pause();
        return;
      }
      setState(() => _index++);
      _centerOnCurrent();
    });
  }

  void _pause() {
    _ticker?.cancel();
    if (mounted) setState(() => _isPlaying = false);
  }

  void _seek(double value) {
    _pause();
    setState(() => _index = value.round());
    _centerOnCurrent();
  }

  void _centerOnCurrent() {
    _mapController.move(_route[_index], _mapController.camera.zoom);
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

    final current = points[_index];

    return Scaffold(
      appBar: AppBar(title: Text('${widget.userName} · Replay')),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(initialCenter: _route.first, initialZoom: 15),
              children: [
                TileLayer(
                  urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                  subdomains: const ['a', 'b', 'c'],
                  userAgentPackageName: 'com.example.legacytracker',
                ),
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
                      point: _route[_index],
                      width: 22,
                      height: 22,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ],
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
                    value: _index.toDouble(),
                    min: 0,
                    max: (points.length - 1).toDouble(),
                    divisions: points.length > 1 ? points.length - 1 : 1,
                    onChanged: points.length > 1 ? _seek : null,
                  ),
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
            ),
          ),
        ],
      ),
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
