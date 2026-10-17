import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widgets/tracking_map_layer.dart';

/// The map style the app opens with, kept on this device only.
class MapSettings extends ChangeNotifier {
  MapSettings({Future<SharedPreferences>? prefs})
    : _prefsFuture = prefs ?? SharedPreferences.getInstance() {
    _load();
  }

  static const _key = 'default_map_layer';

  final Future<SharedPreferences> _prefsFuture;
  MapLayer _defaultLayer = MapLayer.standard;

  MapLayer get defaultLayer => _defaultLayer;

  Future<void> _load() async {
    final prefs = await _prefsFuture;
    final name = prefs.getString(_key);
    final layer = MapLayer.values.where((l) => l.name == name).firstOrNull;
    if (layer != null && layer != _defaultLayer) {
      _defaultLayer = layer;
      notifyListeners();
    }
  }

  Future<void> setDefaultLayer(MapLayer layer) async {
    if (layer == _defaultLayer) return;
    _defaultLayer = layer;
    notifyListeners();
    final prefs = await _prefsFuture;
    await prefs.setString(_key, layer.name);
  }
}
