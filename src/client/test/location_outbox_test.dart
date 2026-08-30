import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:legacytracker/src/features/location/location_outbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('enqueue persists queued locations', () async {
    final outbox = LocationOutbox();
    await outbox.enqueue({'foo': 'bar'});

    final queued = await outbox.read();
    expect(queued, hasLength(1));
    expect(queued.single['foo'], 'bar');
  });

  test('drain drops consecutive duplicate coords+timestamp', () async {
    final outbox = LocationOutbox();
    final point = {
      'coords': {'latitude': 45.0, 'longitude': 7.0},
      'timestamp': '2026-08-30T00:00:00.000Z',
    };
    final other = {
      'coords': {'latitude': 45.1, 'longitude': 7.0},
      'timestamp': '2026-08-30T00:00:05.000Z',
    };
    await outbox.write([point, point, other, other, point]);

    final drained = await outbox.drain();
    expect(drained, hasLength(3));
    expect(drained[0]['coords']['latitude'], 45.0);
    expect(drained[1]['coords']['latitude'], 45.1);
    expect(drained[2]['coords']['latitude'], 45.0);
  });

  test('write trims the oldest queued locations', () async {
    final outbox = LocationOutbox();
    final payloads = List.generate(
      LocationOutbox.maxQueuedPoints + 5,
      (index) => {'index': index},
    );

    await outbox.write(payloads);
    final queued = await outbox.read();

    expect(queued, hasLength(LocationOutbox.maxQueuedPoints));
    expect(queued.first['index'], 5);
    expect(queued.last['index'], LocationOutbox.maxQueuedPoints + 4);
  });
}
