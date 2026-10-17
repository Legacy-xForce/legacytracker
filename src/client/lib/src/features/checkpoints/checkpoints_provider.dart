import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/checkpoint.dart';
import '../../data/network/checkpoint_service.dart';

/// The shared checkpoint list. Created above the [MaterialApp] so pushed
/// routes (history, the checkpoints screen) see it too. It refetches on
/// sign-in, app resume and after our own changes; other users' edits show up
/// at the next refresh rather than live. Whether they are drawn on the map is
/// a per-phone choice that is remembered.
class CheckpointsProvider extends ChangeNotifier with WidgetsBindingObserver {
  CheckpointsProvider({
    required this._service,
    Future<SharedPreferences>? prefs,
  }) : _prefsFuture = prefs {
    WidgetsBinding.instance.addObserver(this);
    prefs?.then((loaded) {
      // A toggle made before the stored choice arrived wins.
      if (!_showOnMapChanged) {
        _showOnMap = loaded.getBool(_showOnMapKey) ?? true;
        _notify();
      }
    }, onError: (_) {});
  }

  static const _showOnMapKey = 'checkpoints_on_map';

  final CheckpointService _service;
  final Future<SharedPreferences>? _prefsFuture;
  bool _showOnMap = true;
  bool _showOnMapChanged = false;

  List<Checkpoint> _checkpoints = const [];
  bool _loading = false;
  String? _error;
  String? _userId;
  String? Function() _getAccessToken = () => null;
  bool _disposed = false;

  List<Checkpoint> get checkpoints => _checkpoints;

  /// Whether the map draws the checkpoints. Street labels still resolve names
  /// from the list either way.
  bool get showOnMap => _showOnMap;

  Future<void> setShowOnMap(bool value) async {
    if (value == _showOnMap) return;
    _showOnMap = value;
    _showOnMapChanged = true;
    _notify();
    try {
      await (await _prefsFuture)?.setBool(_showOnMapKey, value);
    } catch (_) {
      // Only the remembered choice is lost.
    }
  }

  Future<void> toggleShowOnMap() => setShowOnMap(!_showOnMap);
  bool get isLoading => _loading;
  String? get error => _error;

  /// Called whenever auth state changes. Loads for a newly signed-in user and
  /// clears everything on sign-out.
  void bindSession({
    required String? userId,
    required String? Function() getAccessToken,
  }) {
    _getAccessToken = getAccessToken;
    if (userId == _userId) return;
    _userId = userId;
    _checkpoints = const [];
    _error = null;
    if (userId == null) {
      _notify();
    } else {
      refresh();
    }
  }

  @visibleForTesting
  void debugSetCheckpoints(List<Checkpoint> checkpoints) {
    _checkpoints = checkpoints;
    _notify();
  }

  Checkpoint? resolve(double latitude, double longitude) =>
      resolveCheckpoint(latitude, longitude, _checkpoints);

  Future<void> refresh() async {
    final token = _getAccessToken();
    if (token == null || _loading) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      final list = await _service.list(token);
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _checkpoints = list;
    } on CheckpointException catch (e) {
      _error = e.message;
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> create({
    required String name,
    required double latitude,
    required double longitude,
    required int radiusM,
  }) async {
    await _service.create(
      _requireToken(),
      name: name,
      latitude: latitude,
      longitude: longitude,
      radiusM: radiusM,
    );
    await _reload();
  }

  Future<void> update(
    String id, {
    required String name,
    required double latitude,
    required double longitude,
    required int radiusM,
  }) async {
    await _service.update(
      _requireToken(),
      id,
      name: name,
      latitude: latitude,
      longitude: longitude,
      radiusM: radiusM,
    );
    await _reload();
  }

  Future<void> delete(String id) async {
    try {
      await _service.delete(_requireToken(), id);
    } on CheckpointException catch (e) {
      // Already gone elsewhere: the list is simply stale.
      if (e.message != 'This checkpoint no longer exists.') rethrow;
    }
    await _reload();
  }

  Future<void> _reload() async {
    _loading = false;
    await refresh();
  }

  String _requireToken() {
    final token = _getAccessToken();
    if (token == null) {
      throw CheckpointException("You're signed out. Sign in again to continue.");
    }
    return token;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _userId != null) refresh();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
