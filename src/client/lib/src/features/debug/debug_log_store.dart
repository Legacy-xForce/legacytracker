import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Append-only, persisted event log for debugging position updates, pacing
/// changes, and background-service activity.
///
/// Backed by [SharedPreferences] (rather than an in-memory list) because
/// entries are written from multiple isolates — the main UI isolate and the
/// background-task isolate ([BackgroundLocationHandler]) — and need to
/// survive the app being fully closed, so the activity view can show what
/// happened while it wasn't running.
class DebugLogStore {
  DebugLogStore._();

  static const String _storageKey = 'debug_activity_log';
  static const int maxEntries = 300;

  static Future<void> log(String category, String message) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _read(prefs);
    entries.add({
      'ts': DateTime.now().toIso8601String(),
      'cat': category,
      'msg': message,
    });
    final trimmed = entries.length > maxEntries
        ? entries.sublist(entries.length - maxEntries)
        : entries;
    await prefs.setString(_storageKey, jsonEncode(trimmed));
  }

  static Future<List<Map<String, dynamic>>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return _read(prefs);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }

  static List<Map<String, dynamic>> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];

    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];

    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }
}
