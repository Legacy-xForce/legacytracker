import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../../core/constants.dart';
import 'map_geometry.dart';
import 'marker_icons.dart';
import 'tracking_map_layer.dart';

/// Annotation layers in draw order. Beams are drawn under people, calendar
/// events under people, checkpoints under everything but the route.
enum MapMarkerLayer { beam, base, event, cluster, user }

/// A bitmap marker the map renders through a native point annotation.
class MapMarker {
  const MapMarker({
    required this.id,
    required this.position,
    required this.image,
    this.layer = MapMarkerLayer.user,
    this.rotation = 0,
    this.iconSize = 1,
    this.payload,
  });

  final String id;
  final LatLng position;
  final MarkerImage image;
  final MapMarkerLayer layer;

  /// Clockwise rotation in degrees, used by heading beams.
  final double rotation;
  final double iconSize;

  /// Boxing-free hand-off to the tap callback (a peer, cluster or event).
  final Object? payload;
}

/// A native text label, e.g. the name under a checkpoint circle.
class MapTextMarker {
  const MapTextMarker({
    required this.id,
    required this.position,
    required this.text,
  });

  final String id;
  final LatLng position;
  final String text;
}

/// A checkpoint circle whose radius is honoured in metres.
class MapCheckpointOverlay {
  const MapCheckpointOverlay({
    required this.id,
    required this.center,
    required this.radiusMeters,
    this.label,
    this.color = const Color(0xFF82D5C8),
  });

  final String id;
  final LatLng center;
  final double radiusMeters;

  /// Shown when the map is zoomed in enough, as on the old map.
  final String? label;

  /// Outline colour; the fill uses the same colour at 14% opacity.
  final Color color;
}

/// A route line for replay.
class MapPolyline {
  const MapPolyline({
    required this.id,
    required this.points,
    required this.color,
    required this.width,
  });

  final String id;
  final List<LatLng> points;
  final Color color;
  final double width;
}

/// Mapbox-powered map surface shared by live tracking, replay and the
/// checkpoint editor.
///
/// Annotation managers (and style images) die with the style, so they are
/// rebuilt on every `style.load`. Outside that event this widget only diffs
/// markers, labels, circles and lines, keeping the map itself alive.
class MapboxMapWidget extends StatefulWidget {
  const MapboxMapWidget({
    super.key,
    required this.accessToken,
    required this.initialCenter,
    required this.initialZoom,
    required this.style,
    this.darkMode = true,
    this.markers = const [],
    this.labels = const [],
    this.checkpoints = const [],
    this.polylines = const [],
    this.showCheckpointLabels = false,
    this.onMarkerTap,
    this.onMapCreated,
    this.onStyleLoaded,
    this.onCameraChanged,
    this.onLoadError,
  });

  final String accessToken;
  final LatLng initialCenter;
  final double initialZoom;
  final MapLayer style;
  final bool darkMode;
  final List<MapMarker> markers;
  final List<MapTextMarker> labels;
  final List<MapCheckpointOverlay> checkpoints;
  final List<MapPolyline> polylines;
  final bool showCheckpointLabels;
  final ValueChanged<MapMarker>? onMarkerTap;
  final ValueChanged<MapboxMap>? onMapCreated;
  final VoidCallback? onStyleLoaded;
  final ValueChanged<CameraState>? onCameraChanged;
  final ValueChanged<MapLoadingErrorEventData>? onLoadError;

  @override
  State<MapboxMapWidget> createState() => _MapboxMapWidgetState();
}

class _MapboxMapWidgetState extends State<MapboxMapWidget> {
  MapboxMap? _map;
  late final ViewportState _viewport;

  PolylineAnnotationManager? _lineManager;
  PolygonAnnotationManager? _checkpointManager;
  PointAnnotationManager? _labelManager;
  final Map<MapMarkerLayer, PointAnnotationManager> _pointManagers = {};
  final List<Cancelable> _tapSubscriptions = [];

  final Map<String, PointAnnotation> _annotations = {};
  final Map<String, String> _annotationSpecs = {};
  final Map<String, PointAnnotation> _labelAnnotations = {};
  final Map<String, String> _labelSpecs = {};
  final Map<String, PolygonAnnotation> _checkpointAnnotations = {};
  final Map<String, String> _checkpointSpecs = {};
  final Map<String, PolylineAnnotation> _lineAnnotations = {};
  final Map<String, String> _lineSpecs = {};
  final Set<String> _addedImages = {};

  Future<void>? _managerSetup;
  bool _managersReady = false;
  bool _styleReady = false;
  bool _syncing = false;
  bool _dirty = false;
  int _styleEpoch = 0;

  @override
  void initState() {
    super.initState();
    _viewport = CameraViewportState(
      center: _point(widget.initialCenter),
      zoom: widget.initialZoom,
    );
    if (widget.accessToken.isNotEmpty) {
      MapboxOptions.setAccessToken(widget.accessToken);
    }
  }

  @override
  void didUpdateWidget(covariant MapboxMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.accessToken.isNotEmpty &&
        widget.accessToken != oldWidget.accessToken) {
      MapboxOptions.setAccessToken(widget.accessToken);
    }
    if (widget.style != oldWidget.style) {
      _styleReady = false;
      _styleEpoch++;
      final map = _map;
      if (map != null) {
        map.loadStyleURI(_styleUri(widget.style));
      }
    }
    if (widget.darkMode != oldWidget.darkMode) {
      _applyLightPreset();
    }
    _syncAll();
  }

  @override
  void dispose() {
    _cancelTaps();
    super.dispose();
  }

  void _cancelTaps() {
    for (final subscription in _tapSubscriptions) {
      subscription.cancel();
    }
    _tapSubscriptions.clear();
  }

  String _styleUri(MapLayer style) {
    switch (style) {
      case MapLayer.satellite:
        return MapboxStyles.STANDARD_SATELLITE;
      case MapLayer.standard:
        return MapboxStyles.STANDARD;
    }
  }

  Point _point(LatLng point) =>
      Point(coordinates: Position(point.longitude, point.latitude));

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    try {
      await map.setBounds(
        CameraBoundsOptions(
          minZoom: AppConstants.minZoom,
          maxZoom: AppConstants.maxZoom,
        ),
      );
    } catch (_) {
      // Camera limits are a parity nicety; the map still works without them.
    }
    try {
      await map.gestures.updateSettings(
        GesturesSettings(rotateEnabled: false, pitchEnabled: false),
      );
    } catch (_) {
      // Older native SDKs may not expose gesture settings.
    }
    if (!mounted) return;
    widget.onMapCreated?.call(map);
  }

  Future<void> _onStyleLoaded() async {
    if (_map == null) return;
    final epoch = ++_styleEpoch;
    try {
      await _ensureManagers();
    } catch (_) {
      return;
    }
    if (epoch != _styleEpoch || !_managersReady) return;

    // The SDK re-adds annotation managers after a style reload, so reuse them
    // and repopulate rather than creating a second set of layers.
    await _clearAnnotations();
    _addedImages.clear();
    _styleReady = true;
    await _applyLightPreset();
    await _syncAll();
    widget.onStyleLoaded?.call();
  }

  Future<void> _ensureManagers() {
    final pending = _managerSetup;
    if (pending != null) return pending;
    final future = _createManagers().catchError((Object error) {
      _managerSetup = null;
      throw error;
    });
    _managerSetup = future;
    return future;
  }

  Future<void> _createManagers() async {
    if (_managersReady) return;
    final map = _map;
    if (map == null) return;
    final lineManager = await map.annotations.createPolylineAnnotationManager();
    final checkpointManager = await map.annotations
        .createPolygonAnnotationManager();
    final labelManager = await map.annotations.createPointAnnotationManager();
    final beamManager = await map.annotations.createPointAnnotationManager();
    final baseManager = await map.annotations.createPointAnnotationManager();
    final eventManager = await map.annotations.createPointAnnotationManager();
    final clusterManager = await map.annotations.createPointAnnotationManager();
    final userManager = await map.annotations.createPointAnnotationManager();

    _lineManager = lineManager;
    _checkpointManager = checkpointManager;
    _labelManager = labelManager;
    _pointManagers
      ..[MapMarkerLayer.beam] = beamManager
      ..[MapMarkerLayer.base] = baseManager
      ..[MapMarkerLayer.event] = eventManager
      ..[MapMarkerLayer.cluster] = clusterManager
      ..[MapMarkerLayer.user] = userManager;

    for (final manager in _pointManagers.values) {
      await manager.setIconAllowOverlap(true);
      await manager.setIconIgnorePlacement(true);
      await manager.setTextAllowOverlap(true);
      _registerTaps(manager);
    }
    await labelManager.setIconAllowOverlap(true);
    await labelManager.setIconIgnorePlacement(true);
    await labelManager.setTextAllowOverlap(true);
    _managersReady = true;
  }

  Future<void> _clearAnnotations() async {
    Future<void> clear(Future<void> Function() delete) async {
      try {
        await delete();
      } catch (_) {
        // The style observer may not have re-created the manager layer yet.
      }
    }

    for (final manager in _pointManagers.values) {
      await clear(manager.deleteAll);
    }
    if (_labelManager != null) await clear(_labelManager!.deleteAll);
    if (_checkpointManager != null) await clear(_checkpointManager!.deleteAll);
    if (_lineManager != null) await clear(_lineManager!.deleteAll);
    _annotations.clear();
    _annotationSpecs.clear();
    _labelAnnotations.clear();
    _labelSpecs.clear();
    _checkpointAnnotations.clear();
    _checkpointSpecs.clear();
    _lineAnnotations.clear();
    _lineSpecs.clear();
  }

  void _registerTaps(PointAnnotationManager manager) {
    _tapSubscriptions.add(
      manager.tapEvents(
        onTap: (annotation) {
          final markerId = annotation.customData?['markerId'] as String?;
          if (markerId == null) return;
          for (final marker in widget.markers) {
            if (marker.id == markerId && marker.payload != null) {
              widget.onMarkerTap?.call(marker);
              return;
            }
          }
        },
      ),
    );
  }

  Future<void> _applyLightPreset() async {
    final map = _map;
    if (map == null || !_styleReady) return;
    try {
      await map.style.setStyleImportConfigProperty(
        'basemap',
        'lightPreset',
        widget.darkMode ? 'night' : 'day',
      );
    } catch (_) {
      // Standard Satellite and older style versions may not expose the
      // property; the map still renders, just without theme matching.
    }
  }

  Future<void> _syncAll() async {
    if (!_styleReady || _map == null) return;
    if (_syncing) {
      _dirty = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _dirty = false;
        await _syncOnce();
      } while (_dirty);
    } catch (_) {
      // A style switch can race an in-flight sync; the next style.load or
      // widget update retries from a clean state.
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncOnce() async {
    final usedImages = <String>{
      for (final marker in widget.markers) marker.image.id,
    };
    for (final marker in widget.markers) {
      await _ensureImage(marker.image);
    }

    await _syncPointLayer(MapMarkerLayer.beam, MapMarkerLayer.beam);
    await _syncPointLayer(MapMarkerLayer.base, MapMarkerLayer.base);
    await _syncPointLayer(MapMarkerLayer.event, MapMarkerLayer.event);
    await _syncPointLayer(MapMarkerLayer.cluster, MapMarkerLayer.cluster);
    await _syncPointLayer(MapMarkerLayer.user, MapMarkerLayer.user);
    await _syncLabels();
    await _syncCheckpoints();
    await _syncLines();
    await _removeUnusedImages(usedImages);
  }

  Future<void> _ensureImage(MarkerImage image) async {
    if (_addedImages.contains(image.id) || image.rgba.isEmpty) return;
    final map = _map;
    if (map == null) return;
    await map.style.addStyleImage(
      image.id,
      image.scale,
      MbxImage(width: image.width, height: image.height, data: image.rgba),
      false,
      const [],
      const [],
      null,
    );
    _addedImages.add(image.id);
  }

  Future<void> _removeUnusedImages(Set<String> used) async {
    final map = _map;
    if (map == null) return;
    final unused = _addedImages.difference(used).toList();
    for (final id in unused) {
      try {
        await map.style.removeStyleImage(id);
      } catch (_) {
        // The image may already be gone with a style switch.
      }
      _addedImages.remove(id);
    }
  }

  Future<void> _syncPointLayer(
    MapMarkerLayer layer,
    MapMarkerLayer source,
  ) async {
    final manager = _pointManagers[layer];
    if (manager == null) return;
    final desired = <String, MapMarker>{
      for (final marker in widget.markers)
        if (marker.layer == source) '${layer.name}:${marker.id}': marker,
    };
    final existingKeys = _annotations.keys
        .where((key) => key.startsWith('${layer.name}:'))
        .toList();

    for (final entry in desired.entries) {
      final key = entry.key;
      final marker = entry.value;
      final spec = _markerSpec(marker);
      final annotation = _annotations[key];
      if (annotation == null) {
        final created = await manager.create(_pointOptions(marker));
        _annotations[key] = created;
        _annotationSpecs[key] = spec;
      } else {
        if (_annotationSpecs[key] != spec) {
          _applyPoint(annotation, marker);
          await manager.update(annotation);
          _annotationSpecs[key] = spec;
        }
      }
    }

    for (final key in existingKeys) {
      if (desired.containsKey(key)) continue;
      final annotation = _annotations.remove(key);
      _annotationSpecs.remove(key);
      if (annotation == null) continue;
      await manager.delete(annotation);
    }
  }

  String _markerSpec(MapMarker marker) {
    return '${marker.position.latitude},${marker.position.longitude},'
        '${marker.image.id},${marker.rotation},${marker.iconSize}';
  }

  PointAnnotationOptions _pointOptions(MapMarker marker) {
    final anchored = marker.image.anchorOffsetY;
    return PointAnnotationOptions(
      geometry: _point(marker.position),
      iconImage: marker.image.id,
      iconSize: marker.iconSize,
      iconRotate: marker.rotation,
      iconAnchor: anchored > 0 ? IconAnchor.BOTTOM : IconAnchor.CENTER,
      iconOffset: [0, anchored],
      customData: {'markerId': marker.id},
    );
  }

  void _applyPoint(PointAnnotation annotation, MapMarker marker) {
    final anchored = marker.image.anchorOffsetY;
    annotation.geometry = _point(marker.position);
    annotation.iconImage = marker.image.id;
    annotation.iconSize = marker.iconSize;
    annotation.iconRotate = marker.rotation;
    annotation.iconAnchor = anchored > 0
        ? IconAnchor.BOTTOM
        : IconAnchor.CENTER;
    annotation.iconOffset = [0, anchored];
    annotation.customData = {'markerId': marker.id};
  }

  Future<void> _syncLabels() async {
    final manager = _labelManager;
    if (manager == null) return;
    final wanted = <String, MapTextMarker>{
      for (final label in widget.labels) label.id: label,
      if (widget.showCheckpointLabels)
        for (final checkpoint in widget.checkpoints)
          if (checkpoint.label != null)
            'checkpoint-${checkpoint.id}': MapTextMarker(
              id: 'checkpoint-${checkpoint.id}',
              position: checkpoint.center,
              text: checkpoint.label!,
            ),
    };

    final existingKeys = _labelAnnotations.keys.toList();
    for (final entry in wanted.entries) {
      final key = entry.key;
      final label = entry.value;
      final spec =
          '${label.position.latitude},${label.position.longitude},${label.text}';
      final annotation = _labelAnnotations[key];
      if (annotation == null) {
        final created = await manager.create(_labelOptions(label));
        _labelAnnotations[key] = created;
        _labelSpecs[key] = spec;
      } else if (_labelSpecs[key] != spec) {
        _applyLabel(annotation, label);
        await manager.update(annotation);
        _labelSpecs[key] = spec;
      }
    }
    for (final key in existingKeys) {
      if (wanted.containsKey(key)) continue;
      final annotation = _labelAnnotations.remove(key);
      _labelSpecs.remove(key);
      if (annotation != null) await manager.delete(annotation);
    }
  }

  PointAnnotationOptions _labelOptions(MapTextMarker label) {
    return PointAnnotationOptions(
      geometry: _point(label.position),
      textField: label.text,
      textSize: 12,
      textColor: 0xFFFFFFFF,
      textHaloColor: 0xEB252B2A,
      textHaloWidth: 2,
      textOffset: [0, -1.2],
      textAnchor: TextAnchor.CENTER,
    );
  }

  void _applyLabel(PointAnnotation annotation, MapTextMarker label) {
    annotation.geometry = _point(label.position);
    annotation.textField = label.text;
  }

  Future<void> _syncCheckpoints() async {
    final manager = _checkpointManager;
    if (manager == null) return;
    final wanted = <String, MapCheckpointOverlay>{
      for (final checkpoint in widget.checkpoints) checkpoint.id: checkpoint,
    };
    final existingKeys = _checkpointAnnotations.keys.toList();
    for (final entry in wanted.entries) {
      final overlay = entry.value;
      final spec =
          '${overlay.center.latitude},${overlay.center.longitude},'
          '${overlay.radiusMeters},${overlay.color.toARGB32()}';
      final annotation = _checkpointAnnotations[entry.key];
      if (annotation == null) {
        final created = await manager.create(
          PolygonAnnotationOptions(
            geometry: _checkpointGeometry(overlay),
            fillColor: overlay.color.withValues(alpha: 0.14).toARGB32(),
            fillOutlineColor: overlay.color.toARGB32(),
            fillOpacity: 1,
          ),
        );
        _checkpointAnnotations[entry.key] = created;
        _checkpointSpecs[entry.key] = spec;
      } else if (_checkpointSpecs[entry.key] != spec) {
        annotation.geometry = _checkpointGeometry(overlay);
        annotation.fillColor = overlay.color.withValues(alpha: 0.14).toARGB32();
        annotation.fillOutlineColor = overlay.color.toARGB32();
        await manager.update(annotation);
        _checkpointSpecs[entry.key] = spec;
      }
    }
    for (final key in existingKeys) {
      if (wanted.containsKey(key)) continue;
      final annotation = _checkpointAnnotations.remove(key);
      _checkpointSpecs.remove(key);
      if (annotation != null) await manager.delete(annotation);
    }
  }

  Polygon _checkpointGeometry(MapCheckpointOverlay overlay) {
    final ring = circleRing(overlay.center, overlay.radiusMeters);
    return Polygon(
      coordinates: [
        [for (final point in ring) Position(point.longitude, point.latitude)],
      ],
    );
  }

  Future<void> _syncLines() async {
    final manager = _lineManager;
    if (manager == null) return;
    final wanted = <String, MapPolyline>{
      for (final line in widget.polylines) line.id: line,
    };
    final existingKeys = _lineAnnotations.keys.toList();
    for (final entry in wanted.entries) {
      final line = entry.value;
      final spec =
          '${line.color.toARGB32()},${line.width},'
          '${line.points.length}:'
          '${line.points.isEmpty ? '' : '${line.points.first.latitude},${line.points.first.longitude},${line.points.last.latitude},${line.points.last.longitude}'}';
      final annotation = _lineAnnotations[entry.key];
      if (annotation == null) {
        final created = await manager.create(_lineOptions(line));
        _lineAnnotations[entry.key] = created;
        _lineSpecs[entry.key] = spec;
      } else if (_lineSpecs[entry.key] != spec) {
        annotation.geometry = _lineGeometry(line);
        annotation.lineColor = line.color.toARGB32();
        annotation.lineWidth = line.width;
        await manager.update(annotation);
        _lineSpecs[entry.key] = spec;
      }
    }
    for (final key in existingKeys) {
      if (wanted.containsKey(key)) continue;
      final annotation = _lineAnnotations.remove(key);
      _lineSpecs.remove(key);
      if (annotation != null) await manager.delete(annotation);
    }
  }

  PolylineAnnotationOptions _lineOptions(MapPolyline line) {
    return PolylineAnnotationOptions(
      geometry: _lineGeometry(line),
      lineColor: line.color.toARGB32(),
      lineWidth: line.width,
      lineJoin: LineJoin.ROUND,
    );
  }

  LineString _lineGeometry(MapPolyline line) {
    return LineString(
      coordinates: [
        for (final point in line.points)
          Position(point.longitude, point.latitude),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MapWidget(
      styleUri: _styleUri(widget.style),
      viewport: _viewport,
      onMapCreated: _onMapCreated,
      onStyleLoadedListener: (_) => _onStyleLoaded(),
      onMapLoadErrorListener: (error) => widget.onLoadError?.call(error),
      onCameraChangeListener: (event) =>
          widget.onCameraChanged?.call(event.cameraState),
    );
  }
}
