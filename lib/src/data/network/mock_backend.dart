import 'dart:async';
import 'dart:math';

import '../models/location_model.dart';
import '../models/user_model.dart';

class MockBackend {
  static final MockBackend _instance = MockBackend._internal();
  factory MockBackend() => _instance;

  final _peerController = StreamController<List<UserProfile>>.broadcast();
  final List<UserProfile> _peers = [
    UserProfile(
      id: 'alice',
      name: 'Alice',
      avatarUrl: 'https://i.pravatar.cc/150?img=32',
      lastLocation: LocationPoint(latitude: 37.7764, longitude: -122.4241, speed: 0.8),
    ),
    UserProfile(
      id: 'bobby',
      name: 'Bobby',
      avatarUrl: 'https://i.pravatar.cc/150?img=12',
      lastLocation: LocationPoint(latitude: 37.7721, longitude: -122.4173, speed: 1.8),
    ),
    UserProfile(
      id: 'carla',
      name: 'Carla',
      avatarUrl: 'https://i.pravatar.cc/150?img=47',
      lastLocation: LocationPoint(latitude: 37.7785, longitude: -122.4149, speed: 0.4),
    ),
  ];

  Timer? _updateTimer;

  MockBackend._internal() {
    _schedulePeerUpdates();
  }

  Stream<List<UserProfile>> get peerStream => _peerController.stream;

  Future<bool> sendLocation(UserProfile profile) async {
    await Future.delayed(const Duration(milliseconds: 250));
    return true;
  }

  void _schedulePeerUpdates() {
    _updateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final random = Random();
      for (final peer in _peers) {
        final oldLocation = peer.lastLocation;
        if (oldLocation == null) {
          peer.lastLocation = LocationPoint(
            latitude: 37.7749 + random.nextDouble() * 0.01 - 0.005,
            longitude: -122.4194 + random.nextDouble() * 0.01 - 0.005,
            speed: random.nextDouble() * 2.4,
          );
        } else {
          peer.lastLocation = LocationPoint(
            latitude: oldLocation.latitude + random.nextDouble() * 0.0008 - 0.0004,
            longitude: oldLocation.longitude + random.nextDouble() * 0.0008 - 0.0004,
            speed: random.nextDouble() * 3.2,
          );
          peer.history = [peer.lastLocation!, ...peer.history].take(20).toList();
        }
      }
      _peerController.add(List.unmodifiable(_peers));
    });
    _peerController.add(List.unmodifiable(_peers));
  }

  void dispose() {
    _updateTimer?.cancel();
    _peerController.close();
  }
}
