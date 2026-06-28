import '../models/location_model.dart';
import '../models/user_model.dart';

abstract class Backend {
  Stream<List<UserProfile>> get peerStream;

  /// Send a location update over WebSocket (foreground realtime mode).
  ///
  /// [batteryLevel] (0–100) and [isCharging] reflect the device's current power
  /// state and are omitted from the payload when null.
  void sendLocationRealtime(
    LocationPoint point, {
    int? batteryLevel,
    bool? isCharging,
  });

  /// HTTP fallback used only by the background isolate; kept for mock/test use.
  Future<bool> sendLocation(UserProfile profile);

  Future<void> initialize();

  /// Register a device FCM token so the server can push pacing-mode changes.
  Future<void> registerFcmToken(String token);

  Future<void> dispose();
}
