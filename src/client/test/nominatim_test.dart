import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/data/network/nominatim.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_location_street_label.dart';

void main() {
  test('the throttle spaces turns out and keeps their order', () async {
    final throttle = NominatimThrottle(const Duration(milliseconds: 60));
    final order = <int>[];
    final stamps = <DateTime>[];
    await Future.wait([
      for (var i = 0; i < 3; i++)
        throttle.acquire().then((_) {
          order.add(i);
          stamps.add(DateTime.now());
        }),
    ]);
    expect(order, [0, 1, 2]);
    expect(
      stamps[2].difference(stamps[0]).inMilliseconds,
      greaterThanOrEqualTo(100),
    );
  });

  test('LruMap forgets the oldest entry and refreshes on read', () {
    final map = LruMap<String, int>(2);
    map['a'] = 1;
    map['b'] = 2;
    expect(map['a'], 1);
    map['c'] = 3;
    expect(map.containsKey('b'), isFalse);
    expect(map.containsKey('a'), isTrue);
    expect(map.length, 2);
  });

  test('describeAddress prefers road and number, then city, then name', () {
    expect(
      describeAddress({
        'address': {'road': 'Via Roma', 'house_number': '4', 'city': 'Torino'},
      }),
      'Via Roma 4, Torino',
    );
    expect(
      describeAddress({
        'address': {'town': 'Asti'},
      }),
      'Asti',
    );
    expect(describeAddress({'display_name': ' Somewhere '}), 'Somewhere');
    expect(describeAddress({'address': <String, dynamic>{}}), isNull);
  });
}
