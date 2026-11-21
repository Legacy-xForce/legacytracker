import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which GitHub release the Android self-updater follows.
enum UpdateChannel {
  stable('Stable', 'Published releases, rolled out to everyone.'),
  nightly('Nightly', 'Unreleased builds from main, replaced on every CI run.');

  const UpdateChannel(this.label, this.description);

  final String label;
  final String description;

  static UpdateChannel parse(String? name) =>
      UpdateChannel.values.where((c) => c.name == name).firstOrNull ??
      UpdateChannel.stable;
}

/// The channel choice, kept on this device only. Changing it reconfigures the
/// native updater through [onChanged], which clears cached builds from the old
/// channel and rechecks immediately.
class UpdateChannelSettings extends ChangeNotifier {
  UpdateChannelSettings({
    Future<SharedPreferences>? prefs,
    this.onChanged,
  }) : _prefsFuture = prefs ?? SharedPreferences.getInstance() {
    _load();
  }

  static const storageKey = 'app_update_channel';

  final Future<SharedPreferences> _prefsFuture;
  final Future<void> Function(UpdateChannel channel)? onChanged;

  UpdateChannel _channel = UpdateChannel.stable;
  bool _userChanged = false;

  UpdateChannel get channel => _channel;

  Future<void> _load() async {
    final prefs = await _prefsFuture;
    // A tap before SharedPreferences finishes loading wins: never undo it.
    if (_userChanged) return;
    final stored = UpdateChannel.parse(prefs.getString(storageKey));
    if (stored != _channel) {
      _channel = stored;
      notifyListeners();
    }
  }

  Future<void> setChannel(UpdateChannel value) async {
    if (value == _channel) return;
    _userChanged = true;
    _channel = value;
    notifyListeners();
    final prefs = await _prefsFuture;
    await prefs.setString(storageKey, value.name);
    await onChanged?.call(value);
  }
}
