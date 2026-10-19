import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/core/speed_color.dart';

void main() {
  test('slow speeds are red', () {
    expect(speedColor(0), const Color(0xFFF44336));
    expect(speedColor(-5), const Color(0xFFF44336));
  });

  test('fast speeds are green', () {
    expect(speedColor(speedColorMaxKmh / 3.6), const Color(0xFF4CAF50));
    expect(speedColor(100), const Color(0xFF4CAF50));
  });

  test('mid speeds move through amber and yellow', () {
    final slow = speedColor(24 / 3.6);
    final middle = speedColor(45 / 3.6);
    final fast = speedColor(100);
    expect(slow, isNot(const Color(0xFFF44336)));
    expect(middle, isNot(slow));
    expect(middle, isNot(fast));
  });
}
