import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'map_variant.dart';
import 'widgets/tracking_map_layer.dart';

/// The map style the app opens with, kept on this device only.
class MapSettings extends ChangeNotifier {
  MapSettings({Future<SharedPreferences>? prefs})
    : _prefsFuture = prefs ?? SharedPreferences.getInstance() {
    _load();
  }

  static const _key = 'default_map_layer';
  static const _variantKey = 'map_variant';

  final Future<SharedPreferences> _prefsFuture;
  MapLayer _defaultLayer = MapLayer.standard;
  MapVariant _mapVariant = MapVariant.auto;

  MapLayer get defaultLayer => _defaultLayer;

  /// The map lighting choice; Auto follows the time of day.
  MapVariant get mapVariant => _mapVariant;

  Future<void> _load() async {
    final prefs = await _prefsFuture;
    final name = prefs.getString(_key);
    final layer = MapLayer.values.where((l) => l.name == name).firstOrNull;
    final variantName = prefs.getString(_variantKey);
    final variant = MapVariant.values
        .where((v) => v.name == variantName)
        .firstOrNull;
    var changed = false;
    if (layer != null && layer != _defaultLayer) {
      _defaultLayer = layer;
      changed = true;
    }
    if (variant != null && variant != _mapVariant) {
      _mapVariant = variant;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> setDefaultLayer(MapLayer layer) async {
    if (layer == _defaultLayer) return;
    _defaultLayer = layer;
    notifyListeners();
    final prefs = await _prefsFuture;
    await prefs.setString(_key, layer.name);
  }

  Future<void> setMapVariant(MapVariant variant) async {
    if (variant == _mapVariant) return;
    _mapVariant = variant;
    notifyListeners();
    final prefs = await _prefsFuture;
    await prefs.setString(_variantKey, variant.name);
  }
}
