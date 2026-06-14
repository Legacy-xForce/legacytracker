import '../models/location_model.dart';
import '../models/user_model.dart';

abstract class Backend {
  Stream<List<UserProfile>> get peerStream;

  /// Send a location update over WebSocket (foreground realtime mode).
  void sendLocationRealtime(LocationPoint point);

  /// HTTP fallback used only by the background isolate; kept for mock/test use.
  Future<bool> sendLocation(UserProfile profile);

  Future<void> initialize();

  /// Register a device FCM token so the server can push pacing-mode changes.
  Future<void> registerFcmToken(String token);

  Future<void> dispose();
}
