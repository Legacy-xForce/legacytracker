import 'dart:async';
import 'dart:collection';

/// Nominatim's usage policy allows about one request per second per client.
/// Street names, place search and event geocoding all take their turn here.
class NominatimThrottle {
  NominatimThrottle([this.spacing = const Duration(milliseconds: 1100)]);

  final Duration spacing;
  Future<void> _chain = Future.value();
  DateTime? _last;

  /// Completes when the caller may send its request; turns come in the order
  /// they were asked for.
  Future<void> acquire() {
    final turn = _chain.then((_) async {
      final last = _last;
      if (last != null) {
        final wait = spacing - DateTime.now().difference(last);
        if (!wait.isNegative && wait > Duration.zero) {
          await Future<void>.delayed(wait);
        }
      }
      _last = DateTime.now();
    });
    _chain = turn;
    return turn;
  }
}

/// The app-wide throttle.
final NominatimThrottle nominatimThrottle = NominatimThrottle();

/// The headers every Nominatim request carries.
const Map<String, String> nominatimHeaders = {
  'accept': 'application/json',
  'user-agent': 'legacytracker/1.0',
};

Uri nominatimUri(String path, Map<String, String> query) =>
    Uri.https('nominatim.openstreetmap.org', path, query);

/// A map that forgets its oldest entry beyond [capacity]; reading refreshes.
class LruMap<K, V> {
  LruMap(this.capacity);

  final int capacity;
  final LinkedHashMap<K, V> _entries = LinkedHashMap();

  int get length => _entries.length;

  bool containsKey(K key) => _entries.containsKey(key);

  V? operator [](K key) {
    if (!_entries.containsKey(key)) return null;
    final value = _entries.remove(key) as V;
    _entries[key] = value;
    return value;
  }

  void operator []=(K key, V value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  V? remove(K key) => _entries.remove(key);

  Iterable<MapEntry<K, V>> get entries => _entries.entries;

  void clear() => _entries.clear();
}
