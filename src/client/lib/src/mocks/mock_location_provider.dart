import 'dart:async';
import 'dart:math';

import '../data/models/location_model.dart';

class MockLocationProvider {
  final _controller = StreamController<LocationPoint>.broadcast();
  Timer? _timer;
  double _heading = 0.0;
  LocationPoint _current = LocationPoint(
    latitude: 37.7749,
    longitude: -122.4194,
    speed: 0.0,
    heading: 0.0,
  );

  MockLocationProvider() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final random = Random();
      final headingDelta = random.nextDouble() * 40 - 20;
      _heading = (_heading + headingDelta + 360) % 360;
      _current = LocationPoint(
        latitude: _current.latitude + (random.nextDouble() - 0.5) * 0.008,
        longitude: _current.longitude + (random.nextDouble() - 0.5) * 0.008,
        speed: random.nextDouble() * 3.2,
        heading: _heading,
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
