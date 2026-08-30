import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LocationOutbox {
  LocationOutbox({this.preferences});

  static const String storageKey = 'pending_location_points';
  static const int maxQueuedPoints = 500;

  final SharedPreferences? preferences;

  Future<SharedPreferences> _prefs() {
    if (preferences != null) {
      return Future.value(preferences);
    }
    return SharedPreferences.getInstance();
  }

  Future<List<Map<String, dynamic>>> read() async {
    final prefs = await _prefs();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return [];
    }

    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Future<void> write(List<Map<String, dynamic>> items) async {
    final prefs = await _prefs();
    final trimmed = items.length > maxQueuedPoints
        ? items.sublist(items.length - maxQueuedPoints)
        : items;
    await prefs.setString(storageKey, jsonEncode(trimmed));
  }

  Future<void> enqueue(Map<String, dynamic> item) async {
    final items = await read();
    items.add(item);
    await write(items);
  }

  Future<List<Map<String, dynamic>>> drain() async {
    final items = await read();
    final prefs = await _prefs();
    await prefs.remove(storageKey);
    return _dedup(items);
  }

  /// Drops consecutive points that carry an identical coords+timestamp — a
  /// partial re-flush (write() after a failed upload) can otherwise re-queue
  /// points that were already accepted.
  static List<Map<String, dynamic>> _dedup(List<Map<String, dynamic>> items) {
    final result = <Map<String, dynamic>>[];
    String? lastKey;
    for (final item in items) {
      final key = jsonEncode([item['coords'], item['timestamp']]);
      if (key == lastKey) continue;
      lastKey = key;
      result.add(item);
    }
    return result;
  }
}
