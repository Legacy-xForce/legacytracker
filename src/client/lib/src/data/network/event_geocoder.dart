import 'dart:async';
import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'place_search_service.dart';

/// Turns an event's free-text location into a map point, remembering every
/// answer (including "no such place") across launches so Nominatim is asked
/// about a given text once. Lookups run one at a time, spaced out to respect
/// its usage policy.
class EventGeocoder {
  EventGeocoder({
    required this._search,
    required Future<SharedPreferences> prefs,
    this.spacing = const Duration(milliseconds: 1100),
  }) {
    ready = prefs.then((loaded) {
      _prefs = loaded;
      _load();
    });
  }

  static const _prefsKey = 'event_geocode_cache_v1';

  final PlaceSearchService _search;
  late final SharedPreferences _prefs;
  final Duration spacing;

  /// Completes once the remembered answers are loaded; [peek] is only
  /// meaningful after that.
  late final Future<void> ready;

  // Normalized text -> point, or null when nothing was found.
  final Map<String, LatLng?> _cache = {};
  Future<void> _queue = Future.value();
  DateTime? _lastRequest;

  static String normalize(String location) =>
      location.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// The answer if we already have one. [known] tells "not found" (known,
  /// null point) apart from "never asked".
  ({bool known, LatLng? point}) peek(String location) {
    final key = normalize(location);
    return (known: _cache.containsKey(key), point: _cache[key]);
  }

  /// Null when the place can't be pinpointed, or the lookup failed (which is
  /// not remembered, so it is retried later).
  Future<LatLng?> resolve(String location) {
    final result = Completer<LatLng?>();
    _queue = _queue.then((_) async {
      try {
        result.complete(await _resolve(location));
      } catch (error) {
        result.complete(null);
      }
    });
    return result.future;
  }

  Future<LatLng?> _resolve(String location) async {
    await ready;
    final key = normalize(location);
    if (_cache.containsKey(key)) return _cache[key];

    final last = _lastRequest;
    if (last != null) {
      final wait = spacing - DateTime.now().difference(last);
      if (!wait.isNegative) await Future<void>.delayed(wait);
    }
    _lastRequest = DateTime.now();
    final results = await _search.search(location);
    final point = results.isEmpty ? null : results.first.point;
    _cache[key] = point;
    await _save();
    return point;
  }

  void _load() {
    try {
      final raw = _prefs.getString(_prefsKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      decoded.forEach((key, value) {
        _cache[key] = value is List
            ? LatLng((value[0] as num).toDouble(), (value[1] as num).toDouble())
            : null;
      });
    } catch (_) {
      _cache.clear();
    }
  }

  Future<void> _save() => _prefs.setString(
    _prefsKey,
    jsonEncode({
      for (final entry in _cache.entries)
        entry.key: entry.value == null
            ? null
            : [entry.value!.latitude, entry.value!.longitude],
    }),
  );
}
