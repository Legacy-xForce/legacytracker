import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/features/tracking/widgets/selection_back_guard.dart';

void main() {
  testWidgets('back clears the selected person instead of leaving the map', (
    tester,
  ) async {
    var cleared = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionBackGuard(
          selectionActive: true,
          onClearSelection: () => cleared++,
          child: const Scaffold(body: Text('map')),
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(cleared, 1);
    // The screen is still there: the back press was consumed.
    expect(find.text('map'), findsOneWidget);
  });

  testWidgets('with nobody selected back is left alone', (tester) async {
    var cleared = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionBackGuard(
          selectionActive: false,
          onClearSelection: () => cleared++,
          child: const Scaffold(body: Text('map')),
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(cleared, 0);
  });
}
