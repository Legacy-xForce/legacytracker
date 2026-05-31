import '../models/user_model.dart';

abstract class Backend {
  Stream<List<UserProfile>> get peerStream;
  Future<bool> sendLocation(UserProfile profile);
  Future<void> initialize();
  Future<void> dispose();
}
