import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

/// The selected theme, kept on this device only. It lives above the
/// MaterialApp so switching repaints every screen immediately.
class ThemeSettings extends ChangeNotifier {
  ThemeSettings({Future<SharedPreferences>? prefs})
    : _prefsFuture = prefs ?? SharedPreferences.getInstance() {
    _load();
  }

  static const storageKey = 'app_theme';

  final Future<SharedPreferences> _prefsFuture;
  AppThemeId _themeId = defaultAppThemeId;

  AppThemeId get themeId => _themeId;

  AppTheme get theme => appThemeFor(_themeId);

  Future<void> _load() async {
    final prefs = await _prefsFuture;
    final name = prefs.getString(storageKey);
    final stored = AppThemeId.values.where((id) => id.name == name).firstOrNull;
    if (stored != null && stored != _themeId) {
      _themeId = stored;
      notifyListeners();
    }
  }

  Future<void> setTheme(AppThemeId id) async {
    if (id == _themeId) return;
    _themeId = id;
    notifyListeners();
    final prefs = await _prefsFuture;
    await prefs.setString(storageKey, id.name);
  }
}
