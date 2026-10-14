import 'package:flutter/widgets.dart';

import '../../data/network/sharing_service.dart';

/// Who we are currently not sharing our location with. Created above the
/// [MaterialApp] like the checkpoints list; it loads on sign-in and on app
/// resume, and flips a switch immediately, undoing it if the server refuses.
class SharingProvider extends ChangeNotifier with WidgetsBindingObserver {
  SharingProvider({required this._service}) {
    WidgetsBinding.instance.addObserver(this);
  }

  final SharingService _service;

  Set<String> _hiddenFrom = const {};
  String? _userId;
  String? Function() _getAccessToken = () => null;
  bool _disposed = false;

  /// Whether our location is currently shown to [userId].
  bool isSharingWith(String userId) => !_hiddenFrom.contains(userId);

  void bindSession({
    required String? userId,
    required String? Function() getAccessToken,
  }) {
    _getAccessToken = getAccessToken;
    if (userId == _userId) return;
    _userId = userId;
    _hiddenFrom = const {};
    if (userId == null) {
      _notify();
    } else {
      refresh();
    }
  }

  Future<void> refresh() async {
    final token = _getAccessToken();
    if (token == null) return;
    try {
      _hiddenFrom = await _service.fetchHiddenFrom(token);
      _notify();
    } on SharingException {
      // Keep what we have; the next refresh will try again.
    }
  }

  /// Throws [SharingException] (after restoring the previous state) when the
  /// change couldn't be saved.
  Future<void> setSharing(String userId, bool enabled) async {
    final token = _getAccessToken();
    if (token == null) {
      throw SharingException("You're signed out. Sign in again to continue.");
    }
    final previous = _hiddenFrom;
    _hiddenFrom = enabled
        ? (Set.of(previous)..remove(userId))
        : (Set.of(previous)..add(userId));
    _notify();
    try {
      _hiddenFrom = await _service.setShared(token, userId, enabled: enabled);
    } on SharingException {
      _hiddenFrom = previous;
      rethrow;
    } finally {
      _notify();
    }
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
