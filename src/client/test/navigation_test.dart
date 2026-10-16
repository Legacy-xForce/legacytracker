import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:legacytracker/src/core/formatters.dart';
import 'package:legacytracker/src/core/navigation.dart';

void main() {
  group('directionsUri', () {
    test('opens Google Maps directions off Apple devices', () {
      expect(
        directionsUri(45.1, -9.2, apple: false).toString(),
        'https://www.google.com/maps/dir/?api=1&destination=45.1,-9.2'
        '&travelmode=driving',
      );
    });

    test('opens Apple Maps directions on Apple devices', () {
      expect(
        directionsUri(45.1, -9.2, apple: true).toString(),
        'https://maps.apple.com/?daddr=45.1,-9.2&dirflg=d',
      );
    });
  });

  group('metersBetween', () {
    test(
      'is the straight-line distance, about 10 km per 0.09° of latitude',
      () {
        final meters = metersBetween(LatLng(45.01, 9.2), LatLng(45.1, 9.2));
        expect(meters, closeTo(10007, 20));
        expect(formatDistance(meters), '10 km');
      },
    );

    test('is zero for the same point', () {
      expect(metersBetween(LatLng(45, 9), LatLng(45, 9)), 0);
    });
  });
}
