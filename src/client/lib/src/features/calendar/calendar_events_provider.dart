import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/calendar_event.dart';
import '../../data/network/calendar_service.dart';
import '../../data/network/event_geocoder.dart';

/// Legacy Calendar events that can be pinned on the map. Created above the
/// [MaterialApp] like the checkpoints list. It only does anything for an
/// account whose token has the calendar scope; the overlay is on by default
/// and the choice to hide it is remembered on this phone.
class CalendarEventsProvider extends ChangeNotifier
    with WidgetsBindingObserver {
  CalendarEventsProvider({
    required this._service,
    required this._geocoder,
    required Future<SharedPreferences> prefs,
    this.refreshInterval = const Duration(minutes: 5),
    this.horizon = const Duration(days: 60),
  }) : _prefsFuture = prefs {
    WidgetsBinding.instance.addObserver(this);
    _ready = prefs.then((loaded) {
      _enabled = loaded.getBool(_enabledKey) ?? true;
      _notify();
    });
  }

  static const _enabledKey = 'calendar_events_enabled';

  final CalendarService _service;
  final EventGeocoder _geocoder;
  final Future<SharedPreferences> _prefsFuture;
  late final Future<void> _ready;

  /// How often to refetch while signed in; null turns the timer off.
  final Duration? refreshInterval;

  /// How far ahead events are fetched.
  final Duration horizon;

  List<CalendarEvent> _events = const [];
  bool _enabled = true;
  String? _userId;
  bool _hasScope = false;
  String? Function() _getAccessToken = () => null;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  /// Whether this account can use the overlay at all (decides if the toggle
  /// button is shown).
  bool get available => _userId != null && _hasScope;

  bool get enabled => _enabled;

  /// The events to draw now: placed on the map and not yet over.
  List<CalendarEvent> get visibleEvents {
    if (!available || !_enabled) return const [];
    final now = DateTime.now();
    return [
      for (final event in _events)
        if (event.point != null && !event.isOver(now)) event,
    ];
  }

  void bindSession({
    required String? userId,
    required bool hasCalendarScope,
    required String? Function() getAccessToken,
  }) {
    _getAccessToken = getAccessToken;
    final scope = userId != null && hasCalendarScope;
    if (userId == _userId && scope == _hasScope) return;
    _userId = userId;
    _hasScope = scope;
    _generation++;
    _events = const [];
    _timer?.cancel();
    _timer = null;
    if (available) {
      refresh();
      if (refreshInterval case final interval?) {
        _timer = Timer.periodic(interval, (_) => refresh());
      }
    }
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    _notify();
    try {
      await (await _prefsFuture).setBool(_enabledKey, value);
    } catch (_) {
      // Only the remembered choice is lost.
    }
    if (value) unawaited(refresh());
  }

  Future<void> toggle() => setEnabled(!_enabled);

  Future<void> refresh() async {
    await Future.wait([_ready, _geocoder.ready]);
    final token = _getAccessToken();
    if (!available || !_enabled || token == null) return;
    final generation = _generation;
    final now = DateTime.now();
    try {
      // Start a day back: the calendar's range may be inclusive of whole days
      // in another time zone, and over events are filtered out here anyway.
      final fetched = await _service.list(
        token,
        from: now.subtract(const Duration(days: 1)),
        to: now.add(horizon),
      );
      if (generation != _generation) return;
      _events = [
        for (final event in fetched)
          if (!event.isOver(now)) _placeFromCache(event),
      ];
      _notify();
      await _geocodeMissing(generation);
    } on CalendarException catch (error) {
      if (generation != _generation) return;
      if (error.noAccess) {
        // The token was refused: keep the overlay off until the session or
        // scopes change, rather than failing on every refresh.
        _hasScope = false;
        _events = const [];
        _timer?.cancel();
        _timer = null;
        _notify();
      }
      // Anything else is transient; keep what we have for the next refresh.
    }
  }

  CalendarEvent _placeFromCache(CalendarEvent event) {
    final location = event.location;
    if (location == null) return event;
    return event.withPoint(_geocoder.peek(location).point);
  }

  Future<void> _geocodeMissing(int generation) async {
    final pending = {
      for (final event in _events)
        if (event.location != null && !_geocoder.peek(event.location!).known)
          event.location!,
    };
    for (final location in pending) {
      final point = await _geocoder.resolve(location);
      if (generation != _generation) return;
      if (point == null) continue;
      _events = [
        for (final event in _events)
          if (event.location == location) event.withPoint(point) else event,
      ];
      _notify();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
