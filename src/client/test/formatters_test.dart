import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/core/formatters.dart';

void main() {
  group('formatElapsed', () {
    test('uses the two most significant units', () {
      expect(formatElapsed(const Duration(seconds: 42)), '42s');
      expect(formatElapsed(const Duration(minutes: 12, seconds: 5)), '12m 5s');
      expect(formatElapsed(const Duration(hours: 3, minutes: 20)), '3h 20m');
      expect(formatElapsed(const Duration(days: 42, hours: 1)), '42d 1h');
    });

    test('never shows a bare hour count for multi-day stays', () {
      expect(formatElapsed(const Duration(hours: 1008, minutes: 5)), '42d');
    });

    test('drops a zero second unit', () {
      expect(formatElapsed(const Duration(hours: 3)), '3h');
      expect(formatElapsed(const Duration(minutes: 7)), '7m');
    });

    test('clamps clock skew to zero', () {
      expect(formatElapsed(const Duration(seconds: -3)), '0s');
    });
  });

  test('formatShortDate shows the year only when it differs', () {
    final now = DateTime(2026, 10, 10);
    expect(formatShortDate(DateTime(2026, 10, 8, 23), now: now), '8 Oct');
    expect(formatShortDate(DateTime(2025, 5, 1), now: now), '1 May 2025');
  });

  test('formatClock drops the seconds', () {
    expect(formatClock(DateTime(2026, 10, 8, 8, 5, 59)), '08:05');
  });

  test('formatTripDuration rounds to minutes', () {
    expect(formatTripDuration(const Duration(seconds: 20)), '1m');
    expect(formatTripDuration(const Duration(minutes: 65)), '1h 5m');
  });

  test('formatDistance', () {
    expect(formatDistance(850), '850 m');
    expect(formatDistance(5120), '5.1 km');
    expect(formatDistance(43400), '43 km');
  });
}
