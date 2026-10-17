import 'package:latlong2/latlong.dart';

/// A link that opens turn-by-turn directions to a point: Apple Maps on Apple
/// devices, Google Maps elsewhere (its app picks the link up when installed).
Uri directionsUri(double latitude, double longitude, {required bool apple}) {
  final destination = '$latitude,$longitude';
  return Uri.parse(
    apple
        ? 'https://maps.apple.com/?daddr=$destination&dirflg=d'
        : 'https://www.google.com/maps/dir/?api=1&destination=$destination'
              '&travelmode=driving',
  );
}

/// Like [directionsUri], for a free-text address.
Uri directionsToUri(String destination, {required bool apple}) {
  return Uri.https(
    apple ? 'maps.apple.com' : 'www.google.com',
    apple ? '/' : '/maps/dir/',
    apple
        ? {'daddr': destination, 'dirflg': 'd'}
        : {'api': '1', 'destination': destination, 'travelmode': 'driving'},
  );
}

/// Straight-line (great-circle) distance in metres.
double metersBetween(LatLng a, LatLng b) =>
    const Distance().as(LengthUnit.Meter, a, b);
