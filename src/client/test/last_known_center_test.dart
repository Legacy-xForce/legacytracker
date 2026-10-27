import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:legacytracker/src/features/tracking/last_known_center.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('round-trips a position per account', () async {
    SharedPreferences.setMockInitialValues({});
    final me = LastKnownCenter('me');
    expect(await me.load(), isNull);

    await me.save(const LatLng(45.07, 7.69));
    final loaded = await me.load();
    expect(loaded!.latitude, closeTo(45.07, 1e-9));
    expect(loaded.longitude, closeTo(7.69, 1e-9));

    // Another account on the same device does not inherit the position.
    expect(await LastKnownCenter('other').load(), isNull);
  });

  test('garbage in storage loads as nothing', () async {
    SharedPreferences.setMockInitialValues({
      'lastKnownCenter.wrong': 'not,a,position',
      'lastKnownCenter.nan': 'NaN,7.69',
      'lastKnownCenter.missing': '45.07',
    });
    expect(await LastKnownCenter('wrong').load(), isNull);
    expect(await LastKnownCenter('nan').load(), isNull);
    expect(await LastKnownCenter('missing').load(), isNull);
  });
}
