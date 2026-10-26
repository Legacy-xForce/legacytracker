import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/features/tracking/widgets/selection_back_guard.dart';

void main() {
  testWidgets("back steps the screen's state back instead of leaving", (
    tester,
  ) async {
    var consumed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionBackGuard(
          consumeBack: true,
          onBack: () => consumed++,
          child: const Scaffold(body: Text('map')),
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(consumed, 1);
    // The screen is still there: the back press was consumed.
    expect(find.text('map'), findsOneWidget);
  });

  testWidgets('with nothing to step back to, the press is left alone', (
    tester,
  ) async {
    var consumed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionBackGuard(
          consumeBack: false,
          onBack: () => consumed++,
          child: const Scaffold(body: Text('map')),
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(consumed, 0);
  });
}
