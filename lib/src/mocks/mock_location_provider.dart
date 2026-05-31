import 'dart:async';
import 'dart:math';

import '../data/models/location_model.dart';

class MockLocationProvider {
  final _controller = StreamController<LocationPoint>.broadcast();
  Timer? _timer;
  LocationPoint _current = LocationPoint(latitude: 37.7749, longitude: -122.4194, speed: 0.0);

  MockLocationProvider() {
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      final random = Random();
      _current = LocationPoint(
        latitude: _current.latitude + (random.nextDouble() - 0.5) * 0.0008,
        longitude: _current.longitude + (random.nextDouble() - 0.5) * 0.0008,
        speed: random.nextDouble() * 3.2,
      );
      _controller.add(_current);
    });
  }

  Stream<LocationPoint> get locationStream => _controller.stream;

  Future<void> dispose() async {
    _timer?.cancel();
    await _controller.close();
  }
}
