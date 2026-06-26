import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/app.dart';

void main() {
  testWidgets('app boots into the login shell', (WidgetTester tester) async {
    await tester.pumpWidget(App());
    await tester.pump();

    expect(find.byType(App), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsAtLeastNWidgets(1));
  });
}
