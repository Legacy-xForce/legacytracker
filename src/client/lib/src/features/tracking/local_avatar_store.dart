import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the current user's profile picture on this device only.
///
/// There is no image upload endpoint on the backend yet, so the picked photo
/// is never synced — it's just cached locally (base64 in SharedPreferences)
/// and shown wherever this device renders the signed-in user's own avatar.
class LocalAvatarStore extends ChangeNotifier {
  static const _keyPrefix = 'local_avatar_';

  Uint8List? _bytes;
  String? _userId;

  Uint8List? get bytes => _bytes;

  Future<void> load(String userId) async {
    _userId = userId;
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString('$_keyPrefix$userId');
    _bytes = encoded != null ? base64Decode(encoded) : null;
    notifyListeners();
  }

  Future<void> pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 80,
    );
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    await _save(bytes);
  }

  Future<void> clear() async {
    await _save(null);
  }

  Future<void> _save(Uint8List? bytes) async {
    final userId = _userId;
    if (userId == null) return;

    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyPrefix$userId';
    if (bytes == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, base64Encode(bytes));
    }
    _bytes = bytes;
    notifyListeners();
  }
}
