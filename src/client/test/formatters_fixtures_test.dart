import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/core/formatters.dart';

// The same table the web app's tests read: docs/formatting.md.
void main() {
  final fixtures =
      jsonDecode(File('../../docs/formatting-fixtures.json').readAsStringSync())
          as Map<String, dynamic>;

  void check(String name, String key, String Function(num) run) {
    group(name, () {
      for (final row in (fixtures[name] as List).cast<Map<String, dynamic>>()) {
        test('$key=${row[key]} reads ${row['expected']}', () {
          expect(run(row[key] as num), row['expected']);
        });
      }
    });
  }

  check(
    'formatElapsed',
    'seconds',
    (v) => formatElapsed(Duration(seconds: v.toInt())),
  );
  check(
    'formatUpdatedAgo',
    'seconds',
    (v) => formatUpdatedAgo(Duration(seconds: v.toInt())),
  );
  check(
    'formatTripDuration',
    'seconds',
    (v) => formatTripDuration(Duration(seconds: v.toInt())),
  );
  check('formatDistance', 'meters', (v) => formatDistance(v.toDouble()));
  check(
    'formatDayKilometers',
    'meters',
    (v) => formatDayKilometers(v.toDouble()),
  );
  check('formatSpeed', 'mps', (v) => formatSpeed(v.toDouble()));
}
