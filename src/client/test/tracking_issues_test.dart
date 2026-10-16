import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/data/models/tracking_issue.dart';
import 'package:legacytracker/src/features/location/tracking_engine.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_issues_banner.dart';

void main() {
  group('TrackingIssue', () {
    test('parse keeps known codes in display order, drops the rest', () {
      expect(
        TrackingIssue.parse([
          'battery_optimization',
          'nope',
          7,
          'location_services_off',
        ]),
        [TrackingIssue.locationServicesOff, TrackingIssue.batteryOptimization],
      );
      expect(TrackingIssue.parse(null), isEmpty);
      expect(TrackingIssue.parse('battery_optimization'), isEmpty);
    });

    test('the engine status carries the issues the phone reports', () {
      final status = TrackingStatus.fromMap({
        'issues': ['background_location'],
      });
      expect(status.issues, [TrackingIssue.backgroundLocation]);
      expect(TrackingStatus.fromMap({}).issues, isEmpty);
    });

    test(
      'speaks about someone else in the third person, the viewer as you',
      () {
        expect(
          TrackingIssue.batteryOptimization.summary(name: 'Sam', self: false),
          "Sam should update their phone's Battery Optimization settings.",
        );
        expect(
          TrackingIssue.batteryOptimization.summary(name: 'Sam', self: true),
          "You should update your phone's Battery Optimization settings.",
        );
      },
    );

    test('every issue has a title and fix steps', () {
      for (final issue in TrackingIssue.values) {
        expect(issue.title, isNotEmpty);
        expect(issue.steps, isNotEmpty);
      }
    });
  });

  group('TrackingIssuesBanner', () {
    Future<void> pump(WidgetTester tester, List<TrackingIssue> issues) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrackingIssuesBanner(
              issues: issues,
              name: 'Sam',
              isSelf: false,
            ),
          ),
        ),
      );
    }

    testWidgets('renders nothing without issues', (tester) async {
      await pump(tester, const []);
      expect(
        find.byKey(const ValueKey('tracking-issues-banner')),
        findsNothing,
      );
    });

    testWidgets('names one problem and reveals the steps on request', (
      tester,
    ) async {
      await pump(tester, const [TrackingIssue.batteryOptimization]);
      expect(
        find.text('Battery settings are delaying updates'),
        findsOneWidget,
      );
      expect(
        find.text(
          "Sam should update their phone's Battery Optimization settings.",
        ),
        findsOneWidget,
      );
      expect(find.textContaining('1. '), findsNothing);

      await tester.tap(find.text('Learn how to fix this'));
      await tester.pump();
      expect(find.textContaining('1. '), findsOneWidget);
      expect(find.text('Hide steps'), findsOneWidget);
    });

    testWidgets('lists several problems under one headline', (tester) async {
      await pump(tester, const [
        TrackingIssue.locationServicesOff,
        TrackingIssue.batteryOptimization,
      ]);
      expect(find.text('Location updates are being blocked'), findsOneWidget);
      expect(find.textContaining('•  '), findsNWidgets(2));
    });
  });
}
