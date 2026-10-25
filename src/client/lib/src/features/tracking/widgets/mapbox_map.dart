import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../../data/models/checkpoint.dart';
import 'tracking_map_layer.dart';

/// A single point the map renders: a tracked user, a peer, or a cluster bubble.
class MapPoint {
  const MapPoint({
    required this.id,
    required this.position,
    this.label,
    this.isSelf = false,
  });

  final String id;
  final LatLng position;
  final String? label;
  final bool isSelf;
}

/// Mapbox-powered map: Standard / Standard Satellite styles, point markers for
/// people and circles for checkpoints.
class MapboxMapWidget extends StatefulWidget {
  const MapboxMapWidget({
    super.key,
    required this.accessToken,
    required this.center,
    required this.zoom,
    required this.style,
    required this.points,
    required this.checkpoints,
    required this.onPointTap,
    required this.onMapCreated,
  });

  final String accessToken;
  final LatLng center;
  final double zoom;
  final MapLayer style;
  final List<MapPoint> points;
  final List<Checkpoint> checkpoints;
  final ValueChanged<String> onPointTap;
  /// Called once the map is created. Provides the [MapboxMap] controller.
  final ValueChanged<MapboxMap> onMapCreated;

  @override
  State<MapboxMapWidget> createState() => _MapboxMapWidgetState();
}

class _MapboxMapWidgetState extends State<MapboxMapWidget> {
  MapboxMap? _map;
  PointAnnotationManager? _pointManager;
  CircleAnnotationManager? _circleManager;
  Cancelable? _pointTapSubscription;
  Cancelable? _circleTapSubscription;
  final Map<String, PointAnnotation> _pointsById = {};
  final Map<String, CircleAnnotation> _checkpointsById = {};

  @override
  void initState() {
    super.initState();
    MapboxOptions.setAccessToken(widget.accessToken);
  }

  @override
  void didUpdateWidget(covariant MapboxMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.accessToken != oldWidget.accessToken) {
      MapboxOptions.setAccessToken(widget.accessToken);
    }
    if (widget.style != oldWidget.style) {
      _map?.loadStyleURI(_styleUri(widget.style));
    }
    _syncPoints();
    _syncCheckpoints();
    _syncCamera(oldWidget);
  }

  @override
  void dispose() {
    _pointTapSubscription?.cancel();
    _circleTapSubscription?.cancel();
    super.dispose();
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

  void _syncCamera(MapboxMapWidget oldWidget) {
    final map = _map;
    if (map == null) return;
    final centerChanged =
        widget.center.latitude != oldWidget.center.latitude ||
        widget.center.longitude != oldWidget.center.longitude;
    final zoomChanged = widget.zoom != oldWidget.zoom;
    if (!centerChanged && !zoomChanged) return;
    map.setCamera(CameraOptions(
      center: Point(coordinates: Position(widget.center.longitude, widget.center.latitude)),
      zoom: widget.zoom,
    ));
  }

  Future<void> _syncPoints() async {
    final manager = _pointManager;
    if (manager == null) return;
    await manager.deleteAll();
    _pointsById.clear();
    if (widget.points.isEmpty) return;
    final created = await manager.createMulti(
      widget.points
          .map(
            (point) => PointAnnotationOptions(
              geometry: Point(
                coordinates: Position(
                  point.position.longitude,
                  point.position.latitude,
                ),
              ),
              iconColor: point.isSelf ? 0xFF0985FB : 0xFF333333,
              iconSize: 1.5,
              textField: point.label,
            ),
          )
          .toList(),
    );
    for (var i = 0; i < widget.points.length; i++) {
      final annotation = created[i];
      if (annotation != null) {
        _pointsById[widget.points[i].id] = annotation;
      }
    }
  }

  Future<void> _syncCheckpoints() async {
    final manager = _circleManager;
    if (manager == null) return;
    await manager.deleteAll();
    _checkpointsById.clear();
    if (widget.checkpoints.isEmpty) return;
    final created = await manager.createMulti(
      widget.checkpoints
          .map(
            (cp) => CircleAnnotationOptions(
              geometry: Point(
                coordinates: Position(
                  cp.center.longitude,
                  cp.center.latitude,
                ),
              ),
              circleColor: 0x3382D5C8,
              circleRadius: 20,
              circleOpacity: 0.3,
              circleStrokeColor: 0xFF82D5C8,
              circleStrokeWidth: 1.5,
            ),
          )
          .toList(),
    );
    for (var i = 0; i < widget.checkpoints.length; i++) {
      final annotation = created[i];
      if (annotation != null) {
        _checkpointsById[widget.checkpoints[i].id] = annotation;
      }
    }
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    _pointManager = await map.annotations.createPointAnnotationManager();
    _circleManager = await map.annotations.createCircleAnnotationManager();

    _pointTapSubscription = _pointManager!.tapEvents(onTap: (annotation) {
      final id = _pointsById.entries.firstWhere(
        (e) => e.value == annotation,
        orElse: () => MapEntry('', annotation),
      ).key;
      if (id.isNotEmpty) widget.onPointTap(id);
    });

    _circleTapSubscription = _circleManager!.tapEvents(onTap: (annotation) {
      final id = _checkpointsById.entries.firstWhere(
        (e) => e.value == annotation,
        orElse: () => MapEntry('', annotation),
      ).key;
      if (id.isNotEmpty) widget.onPointTap(id);
    });

    _syncPoints();
    _syncCheckpoints();

    widget.onMapCreated(map);
  }

  @override
  Widget build(BuildContext context) {
    return MapWidget(
      key: widget.key,
      styleUri: _styleUri(widget.style),
      cameraOptions: CameraOptions(
        center: Point(coordinates: Position(widget.center.longitude, widget.center.latitude)),
        zoom: widget.zoom,
      ),
      onMapCreated: _onMapCreated,
    );
  }
}
