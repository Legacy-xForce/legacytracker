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
  static const String _lastTickKey = 'debug_last_tick';
  static const String _lastSuccessKey = 'debug_last_success';
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

  /// Heartbeat markers for the summary header: the last time the background
  /// task woke up ([markTick]) and the last time it actually got a location
  /// out ([markSuccess]). A recent tick with a stale success points at GPS or
  /// upload failures; a stale tick points at the service being killed.
  static Future<void> markTick() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastTickKey, DateTime.now().toIso8601String());
  }

  static Future<void> markSuccess() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSuccessKey, DateTime.now().toIso8601String());
  }

  static Future<DebugLogSummary> summary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return DebugLogSummary(
      lastTick: DateTime.tryParse(prefs.getString(_lastTickKey) ?? ''),
      lastSuccess: DateTime.tryParse(prefs.getString(_lastSuccessKey) ?? ''),
      serviceRunning: prefs.getBool('bg_service_running') ?? false,
      appForeground: prefs.getBool('app_foreground') ?? false,
      pacingMode: prefs.getString('pacing_mode') ?? 'PASSIVE',
      intervalMs: prefs.getInt('bg_current_interval_ms'),
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    await prefs.remove(_lastTickKey);
    await prefs.remove(_lastSuccessKey);
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

/// Snapshot of background-tracking state for the activity log's header.
class DebugLogSummary {
  const DebugLogSummary({
    this.lastTick,
    this.lastSuccess,
    this.serviceRunning = false,
    this.appForeground = false,
    this.pacingMode = 'PASSIVE',
    this.intervalMs,
  });

  final DateTime? lastTick;
  final DateTime? lastSuccess;
  final bool serviceRunning;
  final bool appForeground;
  final String pacingMode;
  final int? intervalMs;
}
