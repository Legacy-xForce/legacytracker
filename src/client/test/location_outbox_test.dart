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
