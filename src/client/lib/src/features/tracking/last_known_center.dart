import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The last fix seen on this device, kept per account so the next cold start
/// opens where the user was instead of sitting on the world view until the
/// tracking engine's first fix arrives seconds later.
class LastKnownCenter {
  LastKnownCenter(this.userId);

  final String userId;

  String get _key => 'lastKnownCenter.$userId';

  /// The stored position, or null when nothing usable was ever saved.
  Future<LatLng?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    final parts = raw.split(',');
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0]);
    final lng = double.tryParse(parts[1]);
    if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) {
      return null;
    }
    return LatLng(lat, lng);
  }

  Future<void> save(LatLng point) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      '${point.latitude},${point.longitude}',
    );
  }
}
