import '../models/user_model.dart';

/// Realtime view of the other users. Our own location is uploaded by the
/// native tracking engine, not through this interface.
abstract class Backend {
  Stream<List<UserProfile>> get peerStream;

  Future<void> initialize();

  /// Register a device FCM token so the server can push tracking commands
  /// (e.g. "someone opened the map — stream live").
  Future<void> registerFcmToken(String token);

  /// Tell the server whether the live map tab is currently in the
  /// foreground. Every viewer sees every driver's pin on the same map, so
  /// the server only asks devices to stream live while some map is actually
  /// open — sitting on the Profile tab shouldn't keep every phone streaming.
  void setMapActive(bool active);

  /// Closes the realtime connection while the app is in the background.
  void suspend();

  /// Reconnects (with a fresh snapshot) when the app is back on screen.
  void resume();

  Future<void> dispose();
}
