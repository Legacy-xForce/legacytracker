import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../../core/constants.dart';
import '../map_variant.dart';
import 'map_geometry.dart';
import 'marker_icons.dart';
import 'tracking_map_layer.dart';

/// Annotation layers in draw order. Checkpoint names sit under everything,
/// beams and calendar events under people, checkpoints under all of them but
/// the route. The person *bitmap* is decoration (`person`, no taps — its box
/// is the beam's footprint and would steal taps from whoever stands under a
/// transparent margin); the tight `user` layer above it carries the hit areas.
enum MapMarkerLayer {
  label,
  beam,
  base,
  event,
  person,
  cluster,
  clusterFace,
  user
}

/// A bitmap marker the map renders through a native point annotation.
class MapMarker {
  const MapMarker({
    required this.id,
    required this.position,
    required this.image,
    this.layer = MapMarkerLayer.user,
    this.rotation = 0,
    this.iconSize = 1,
    this.iconOffset = Offset.zero,
    this.payload,
  });

  final String id;
  final LatLng position;
  final MarkerImage image;
  final MapMarkerLayer layer;

  /// Clockwise rotation in degrees, used by heading beams.
  final double rotation;
  final double iconSize;

  /// Shift of the icon from the annotation's coordinate, in logical pixels
  /// (down-positive with the bottom anchor, so a centred icon shifts up with
  /// a negative y). Used by the transparent hit areas over a cluster bubble's
  /// faces, which must move exactly with the bubble.
  final Offset iconOffset;

  /// Boxing-free hand-off to the tap callback (a peer, cluster or event).
  final Object? payload;
}

/// A checkpoint circle whose radius is honoured in metres.
class MapCheckpointOverlay {
  const MapCheckpointOverlay({
    required this.id,
    required this.center,
    required this.radiusMeters,
    this.color = const Color(0xFF82D5C8),
  });

  final String id;
  final LatLng center;
  final double radiusMeters;

  /// Outline colour; the fill uses the same colour at 14% opacity.
  final Color color;
}

/// Line layers in draw order. The casing manager is created with the route
/// layer as its `below` anchor, so the dark edge is inserted under the coloured
/// route by the style itself rather than by whatever order happened to work.
enum MapPolylineLayer { casing, route }

/// A route line for replay.
class MapPolyline {
  const MapPolyline({
    required this.id,
    required this.points,
    required this.color,
    required this.width,
    this.opacity = 1,
    this.emissiveStrength = 1,
    this.layer = MapPolylineLayer.route,
  });

  final String id;
  final List<LatLng> points;
  final Color color;
  final double width;

  /// Line opacity, separate from the colour: the web map draws its dark route
  /// edge as opaque black at 0.35, and a casing that ever ends up on top then
  /// tints the route instead of replacing it.
  final double opacity;

  /// How much the line emits its own light. The Mapbox style's lighting dims
  /// lines to black at night unless this is 1, which is the default for marker
  /// icons and labels; a replay route has to keep its recorded speeds readable
  /// in a dark theme.
  final double emissiveStrength;

  final MapPolylineLayer layer;
}

/// The annotation inputs of one [MapboxMapWidget].
///
/// Mutable on purpose: marker positions change ~10 times a second, and
/// rebuilding the Flutter tree around a platform-view map just to move a pin
/// costs more than the move itself. Callers update the lists and call
/// [markChanged]; the map re-syncs its annotations without any rebuild.
class MapScene extends ChangeNotifier {
  List<MapMarker> markers = const [];
  List<MapCheckpointOverlay> checkpoints = const [];
  List<MapPolyline> polylines = const [];

  /// How much of the map's bottom edge app chrome (a sheet, a bar) covers.
  /// Mapbox requires its logo and attribution to stay visible, so the native
  /// ornaments are lifted above this band instead of sitting under it.
  double bottomInset = 0;

  void markChanged() => notifyListeners();
}

/// Layers whose annotations open something when tapped. Everything else is
/// decoration, and a tap on decoration would otherwise swallow the tap on the
/// person behind it.
const _interactiveLayers = {
  MapMarkerLayer.base,
  MapMarkerLayer.event,
  MapMarkerLayer.cluster,
  MapMarkerLayer.clusterFace,
  MapMarkerLayer.user,
};

/// The gap the Mapbox SDK leaves between an ornament and the map edge; the
/// widgets keep it above any covered band instead of at the raw edge.
const double _ornamentGap = 4;

/// How far the attribution icon sits from the left edge, clear of the logo.
const double _attributionLeftGap = 92;

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
    required this.scene,
    this.lightPreset = MapLightPreset.day,
    this.onMarkerTap,
    this.onCheckpointTap,
    this.onMapCreated,
    this.onStyleLoaded,
    this.onCameraChanged,
    this.onLoadError,
  });

  final String accessToken;
  final LatLng initialCenter;
  final double initialZoom;
  final MapLayer style;

  /// Owned by the caller; this widget only listens.
  final MapScene scene;

  /// The basemap lighting: the app theme (or the picked map variant) resolved
  /// to one of Mapbox Standard's four presets.
  final MapLightPreset lightPreset;
  final ValueChanged<MapMarker>? onMarkerTap;

  /// A checkpoint circle was tapped (the polygon itself, not its name pill).
  final ValueChanged<MapCheckpointOverlay>? onCheckpointTap;
  final ValueChanged<MapboxMap>? onMapCreated;
  final VoidCallback? onStyleLoaded;
  final ValueChanged<CameraState>? onCameraChanged;
  final ValueChanged<MapLoadingErrorEventData>? onLoadError;

  @override
  State<MapboxMapWidget> createState() => _MapboxMapWidgetState();
}

class _MapboxMapWidgetState extends State<MapboxMapWidget> {
  MapboxMap? _map;

  final Map<MapPolylineLayer, PolylineAnnotationManager> _lineManagers = {};
  PolygonAnnotationManager? _checkpointManager;
  final Map<MapMarkerLayer, PointAnnotationManager> _pointManagers = {};
  final List<Cancelable> _tapSubscriptions = [];

  final Map<String, PointAnnotation> _annotations = {};
  final Map<String, String> _annotationSpecs = {};
  final Map<String, PolygonAnnotation> _checkpointAnnotations = {};
  final Map<String, String> _checkpointSpecs = {};
  final Map<String, PolylineAnnotation> _lineAnnotations = {};
  final Map<String, String> _lineSpecs = {};
  final Set<String> _addedImages = {};
  final Set<String> _failedImages = {};
  double _appliedInset = -1;
  bool _scaleBarHidden = false;
  String? _lastSyncError;

  Future<void>? _managerSetup;
  bool _managersReady = false;
  bool _styleReady = false;
  bool _syncing = false;
  bool _dirty = false;
  int _styleEpoch = 0;

  /// Built once. The map is a platform view, so handing Flutter a fresh widget
  /// every animation frame costs more than the annotation update it carries;
  /// an identical instance lets the subtree skip rebuilding entirely.
  late final Widget _surface;

  @override
  void initState() {
    super.initState();
    widget.scene.addListener(_onSceneChanged);
    if (widget.accessToken.isNotEmpty) {
      MapboxOptions.setAccessToken(widget.accessToken);
    }
    _surface = MapWidget(
      styleUri: mapboxStyleUri(widget.style),
      // The initial camera must be `cameraOptions`: a viewport state is
      // resolved asynchronously by the viewport system, which is how the map
      // flashed the whole globe before jumping to the requested view.
      // ignore: deprecated_member_use
      cameraOptions: CameraOptions(
        center: _point(widget.initialCenter),
        zoom: widget.initialZoom,
      ),
      onMapCreated: _onMapCreated,
      onStyleLoadedListener: (_) => _onStyleLoaded(),
      onMapLoadErrorListener: (error) => widget.onLoadError?.call(error),
      onCameraChangeListener: (event) =>
          widget.onCameraChanged?.call(event.cameraState),
    );
  }

  @override
  void didUpdateWidget(covariant MapboxMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scene != oldWidget.scene) {
      oldWidget.scene.removeListener(_onSceneChanged);
      widget.scene.addListener(_onSceneChanged);
    }
    if (widget.accessToken.isNotEmpty &&
        widget.accessToken != oldWidget.accessToken) {
      MapboxOptions.setAccessToken(widget.accessToken);
    }
    if (widget.style != oldWidget.style) {
      _styleReady = false;
      _styleEpoch++;
      final map = _map;
      if (map != null) {
        map.loadStyleURI(mapboxStyleUri(widget.style));
      }
    }
    if (widget.lightPreset != oldWidget.lightPreset) {
      _applyLightPreset();
    }
    _syncAll();
  }

  @override
  void dispose() {
    widget.scene.removeListener(_onSceneChanged);
    _cancelTaps();
    super.dispose();
  }

  void _onSceneChanged() => _syncAll();

  void _cancelTaps() {
    for (final subscription in _tapSubscriptions) {
      subscription.cancel();
    }
    _tapSubscriptions.clear();
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
    _appliedInset = -1;
    unawaited(_applyOrnaments());
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
    _failedImages.clear();
    _appliedInset = -1;
    _scaleBarHidden = false;
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
    final routeManager = await map.annotations
        .createPolylineAnnotationManager();
    // `below` names the layer that must stay above this one, which pins the
    // dark casing under the coloured route in the style itself instead of
    // relying on whatever creation order happens to produce.
    PolylineAnnotationManager casingManager;
    try {
      casingManager = await map.annotations.createPolylineAnnotationManager(
        below: routeManager.id,
      );
    } catch (_) {
      // A native build that refuses the anchor still gets a casing over the
      // route, but it is opaque black at 0.35, so the route shows through.
      casingManager = await map.annotations.createPolylineAnnotationManager();
    }
    final checkpointManager = await map.annotations
        .createPolygonAnnotationManager();
    // The circle itself opens its checkpoint; the name pill stays decoration.
    _tapSubscriptions.add(
      checkpointManager.tapEvents(
        onTap: (annotation) {
          final id = annotation.customData?['checkpointId'] as String?;
          if (id == null) return;
          for (final checkpoint in widget.scene.checkpoints) {
            if (checkpoint.id == id) {
              widget.onCheckpointTap?.call(checkpoint);
              return;
            }
          }
        },
      ),
    );
    final labelManager = await map.annotations.createPointAnnotationManager();
    final beamManager = await map.annotations.createPointAnnotationManager();
    final baseManager = await map.annotations.createPointAnnotationManager();
    final eventManager = await map.annotations.createPointAnnotationManager();
    final personManager = await map.annotations
        .createPointAnnotationManager();
    final clusterManager = await map.annotations.createPointAnnotationManager();
    // Created after the bubbles so a face's hit area outranks the bubble it
    // sits on: taps go to the topmost annotation only.
    final clusterFaceManager = await map.annotations
        .createPointAnnotationManager();
    final userManager = await map.annotations.createPointAnnotationManager();

    _lineManagers
      ..[MapPolylineLayer.casing] = casingManager
      ..[MapPolylineLayer.route] = routeManager;
    _checkpointManager = checkpointManager;
    _pointManagers
      ..[MapMarkerLayer.label] = labelManager
      ..[MapMarkerLayer.beam] = beamManager
      ..[MapMarkerLayer.base] = baseManager
      ..[MapMarkerLayer.event] = eventManager
      ..[MapMarkerLayer.person] = personManager
      ..[MapMarkerLayer.cluster] = clusterManager
      ..[MapMarkerLayer.clusterFace] = clusterFaceManager
      ..[MapMarkerLayer.user] = userManager;

    for (final entry in _pointManagers.entries) {
      final manager = entry.value;
      await manager.setIconAllowOverlap(true);
      await manager.setIconIgnorePlacement(true);
      await manager.setTextAllowOverlap(true);
      // Mapbox delivers a tap only to the topmost annotation, so the beam and
      // name pills must not compete with the people underneath.
      if (_interactiveLayers.contains(entry.key)) _registerTaps(manager);
    }
    await labelManager.setIconAllowOverlap(true);
    await labelManager.setIconIgnorePlacement(true);
    await labelManager.setTextAllowOverlap(true);
    // Fills and lines are lit and default to no emission, which drains a route
    // or a checkpoint circle to black under the night preset. Icons default to
    // 1. The manager-level setters are used as well as the per-annotation ones
    // because the native side may take emission as a layer-wide constant.
    Future<void> applyLighting(Future<void> Function() run) async {
      try {
        await run();
      } catch (_) {
        // Older native builds may not expose these properties.
      }
    }

    await applyLighting(() => routeManager.setLineEmissiveStrength(1));
    await applyLighting(() => casingManager.setLineEmissiveStrength(1));
    await applyLighting(() => checkpointManager.setFillEmissiveStrength(1));
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
    if (_checkpointManager != null) await clear(_checkpointManager!.deleteAll);
    for (final manager in _lineManagers.values) {
      await clear(manager.deleteAll);
    }
    _annotations.clear();
    _annotationSpecs.clear();
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
          for (final marker in widget.scene.markers) {
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
        widget.lightPreset.name,
      );
    } catch (_) {
      // Standard Satellite and older style versions may not expose the
      // property; the map still renders, just without theme matching.
    }
    await _applySatelliteLight();
  }

  /// Satellite tiles are photographic - the basemap preset cannot darken
  /// them - so the raster layers are dimmed and desaturated to match the
  /// preset, the same compensation the web map applies.
  Future<void> _applySatelliteLight() async {
    final map = _map;
    if (map == null) return;
    final light = satelliteLightFor(widget.lightPreset);
    try {
      for (final layer in await map.style.getStyleLayers()) {
        if (layer == null || layer.type != 'raster') continue;
        await map.style.setStyleLayerProperty(
          layer.id,
          'raster-brightness-min',
          light.brightness,
        );
        await map.style.setStyleLayerProperty(
          layer.id,
          'raster-brightness-max',
          light.brightness,
        );
        await map.style.setStyleLayerProperty(
          layer.id,
          'raster-saturation',
          light.saturation,
        );
      }
    } catch (_) {
      // An older SDK without the raw style API just keeps the imagery.
    }
  }

  /// Mapbox's attribution rules need the logo and the attribution to be on
  /// screen and legible whenever the map is, so both are pinned to the bottom
  /// left and lifted above whatever app chrome covers that strip - the
  /// collapsed tracking sheet sits exactly where the SDK puts them by default.
  /// The scale bar, which the old map never drew and Mapbox does not require,
  /// goes away. Margins are logical pixels; the native side converts them.
  ///
  /// Every field is passed even when it matches the default: iOS releases
  /// before 2.31.1 reset omitted fields to their defaults on a partial update,
  /// which would drop the ornaments back to the raw bottom edge.
  Future<void> _applyOrnaments() async {
    final map = _map;
    // Ornaments are view-level, not style-level: pin them as soon as the map
    // exists so the logo is never drawn at the SDK's default edge first.
    if (map == null) return;
    try {
      if (!_scaleBarHidden) {
        _scaleBarHidden = true;
        await map.scaleBar.updateSettings(
          ScaleBarSettings(
            enabled: false,
            position: OrnamentPosition.TOP_LEFT,
            marginLeft: _ornamentGap,
            marginTop: _ornamentGap,
            marginRight: _ornamentGap,
            marginBottom: _ornamentGap,
          ),
        );
      }
      final inset = widget.scene.bottomInset;
      if (inset == _appliedInset) return;
      _appliedInset = inset;
      final margin = (inset < 0 ? 0 : inset) + _ornamentGap;
      await map.logo.updateSettings(
        LogoSettings(
          enabled: true,
          position: OrnamentPosition.BOTTOM_LEFT,
          marginLeft: _ornamentGap,
          marginTop: _ornamentGap,
          marginRight: _ornamentGap,
          marginBottom: margin,
        ),
      );
      await map.attribution.updateSettings(
        AttributionSettings(
          enabled: true,
          clickable: true,
          position: OrnamentPosition.BOTTOM_LEFT,
          marginLeft: _attributionLeftGap,
          marginTop: _ornamentGap,
          marginRight: _ornamentGap,
          marginBottom: margin,
        ),
      );
    } catch (error) {
      _logSyncError('ornaments', error);
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
    } catch (error) {
      _logSyncError('sync', error);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncOnce() async {
    await _applyOrnaments();
    final usedImages = <String>{
      for (final marker in widget.scene.markers) marker.image.id,
    };
    for (final marker in widget.scene.markers) {
      if (_addedImages.contains(marker.image.id)) continue;
      try {
        await _ensureImage(marker.image);
        _failedImages.remove(marker.image.id);
      } catch (error) {
        // One bad icon must not take down labels, checkpoints or routes.
        _failedImages.add(marker.image.id);
        _logSyncError('image ${marker.image.id}', error);
      }
    }

    for (final layer in MapMarkerLayer.values) {
      await _attempt('layer ${layer.name}', () => _syncPointLayer(layer));
    }
    await _attempt('checkpoints', _syncCheckpoints);
    for (final layer in MapPolylineLayer.values) {
      await _attempt('line layer ${layer.name}', () => _syncLineLayer(layer));
    }
    await _removeUnusedImages(usedImages);
  }

  /// A failed layer must not take the rest of the annotations with it.
  Future<void> _attempt(String what, Future<void> Function() run) async {
    try {
      await run();
    } catch (error) {
      _logSyncError(what, error);
    }
  }

  void _logSyncError(String context, Object error) {
    final message = '$context: $error';
    if (message == _lastSyncError) return;
    _lastSyncError = message;
    debugPrint('Mapbox annotation sync failed — $message');
  }

  Future<void> _ensureImage(MarkerImage image) async {
    if (_addedImages.contains(image.id)) return;
    if (image.png.isEmpty) {
      throw StateError('marker image ${image.id} has no PNG data');
    }
    final map = _map;
    if (map == null) return;
    await map.style.addStyleImage(
      image.id,
      image.scale,
      MbxImage(width: image.width, height: image.height, data: image.png),
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

  Future<void> _syncPointLayer(MapMarkerLayer layer) async {
    final manager = _pointManagers[layer];
    if (manager == null) return;
    final desired = <String, MapMarker>{
      for (final marker in widget.scene.markers)
        if (marker.layer == layer && !_failedImages.contains(marker.image.id))
          '${layer.name}:${marker.id}': marker,
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
        '${marker.image.id},${marker.rotation},${marker.iconSize},'
        '${marker.iconOffset.dx},${marker.iconOffset.dy}';
  }

  PointAnnotationOptions _pointOptions(MapMarker marker) {
    final anchored = marker.image.anchorOffsetY;
    return PointAnnotationOptions(
      geometry: _point(marker.position),
      iconImage: marker.image.id,
      iconSize: marker.iconSize,
      iconRotate: marker.rotation,
      iconAnchor: anchored > 0 ? IconAnchor.BOTTOM : IconAnchor.CENTER,
      iconOffset: [
        marker.iconOffset.dx,
        anchored + marker.iconOffset.dy,
      ],
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
    annotation.iconOffset = [
      marker.iconOffset.dx,
      anchored + marker.iconOffset.dy,
    ];
    annotation.customData = {'markerId': marker.id};
  }

  Future<void> _syncCheckpoints() async {
    final manager = _checkpointManager;
    if (manager == null) return;
    final wanted = <String, MapCheckpointOverlay>{
      for (final checkpoint in widget.scene.checkpoints)
        checkpoint.id: checkpoint,
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
            customData: {'checkpointId': overlay.id},
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

  Future<void> _syncLineLayer(MapPolylineLayer layer) async {
    final manager = _lineManagers[layer];
    if (manager == null) return;
    final wanted = <String, MapPolyline>{};
    final wantedCounts = <String, int>{};
    for (final line in widget.scene.polylines) {
      if (line.layer != layer) continue;
      final count = _linePositions(line).length;
      // A one-point run is not a line, and the native API rejects it.
      if (count > 1) {
        wanted['${layer.name}:${line.id}'] = line;
        wantedCounts['${layer.name}:${line.id}'] = count;
      }
    }
    final existingKeys = _lineAnnotations.keys
        .where((key) => key.startsWith('${layer.name}:'))
        .toList();
    for (final entry in wanted.entries) {
      final key = entry.key;
      final line = entry.value;
      final spec =
          '${line.color.toARGB32()},${line.opacity},'
          '${line.emissiveStrength},${line.width},${wantedCounts[key]}';
      final annotation = _lineAnnotations[key];
      if (annotation == null) {
        try {
          final created = await manager.create(_lineOptions(line));
          _lineAnnotations[key] = created;
          _lineSpecs[key] = spec;
        } catch (error) {
          _logSyncError('line ${line.id}', error);
        }
      } else if (_lineSpecs[key] != spec) {
        try {
          annotation.geometry = _lineGeometry(line);
          annotation.lineColor = line.color.toARGB32();
          annotation.lineOpacity = line.opacity;
          annotation.lineEmissiveStrength = line.emissiveStrength;
          annotation.lineWidth = line.width;
          await manager.update(annotation);
          _lineSpecs[key] = spec;
        } catch (error) {
          _logSyncError('line ${line.id}', error);
        }
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
      lineOpacity: line.opacity,
      lineEmissiveStrength: line.emissiveStrength,
      lineWidth: line.width,
      lineJoin: LineJoin.ROUND,
    );
  }

  LineString _lineGeometry(MapPolyline line) =>
      LineString(coordinates: _linePositions(line));

  /// Repeats the native line API chokes on, and a one-point run is not a line.
  List<Position> _linePositions(MapPolyline line) {
    final positions = <Position>[];
    double? lastLng;
    double? lastLat;
    for (final point in line.points) {
      if (point.longitude == lastLng && point.latitude == lastLat) continue;
      positions.add(Position(point.longitude, point.latitude));
      lastLng = point.longitude;
      lastLat = point.latitude;
    }
    return positions;
  }

  @override
  Widget build(BuildContext context) => _surface;
}
