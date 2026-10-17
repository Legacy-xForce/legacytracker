import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/features/tracking/map_settings.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_map_layer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('defaults to standard', () {
    SharedPreferences.setMockInitialValues({});
    expect(MapSettings().defaultLayer, MapLayer.standard);
  });

  test('the chosen default survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    await MapSettings().setDefaultLayer(MapLayer.satellite);

    final reopened = MapSettings();
    await Future<void>.delayed(Duration.zero);
    expect(reopened.defaultLayer, MapLayer.satellite);
  });

  test('ignores an unknown stored value', () async {
    SharedPreferences.setMockInitialValues({'default_map_layer': 'hybrid'});
    final settings = MapSettings();
    await Future<void>.delayed(Duration.zero);
    expect(settings.defaultLayer, MapLayer.standard);
  });
}
