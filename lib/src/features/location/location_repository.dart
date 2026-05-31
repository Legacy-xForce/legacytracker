import '../../data/models/user_model.dart';
import '../../data/network/mock_backend.dart';
import '../../data/models/location_model.dart';
import 'location_service.dart';

class LocationRepository {
  final LocationService locationService;
  final MockBackend backend;

  LocationRepository({required this.locationService, required this.backend});

  Future<bool> requestPermission() => locationService.requestPermission();

  Stream<LocationPoint> get locationStream => locationService.locationStream;

  Future<void> uploadLocation(UserProfile profile) async {
    await backend.sendLocation(profile);
  }

  Future<void> dispose() async {
    await locationService.dispose();
  }
}
