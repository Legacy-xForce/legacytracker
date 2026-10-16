import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:legacytracker/src/features/connection/connection_banner.dart';
import 'package:legacytracker/src/features/connection/connection_monitor.dart';

/// Probe results are consumed in order, the last one repeating; null is a
/// failed probe.
ConnectionMonitor monitorFor(List<int?> results) {
  var i = 0;
  return ConnectionMonitor(
    probe: () async {
      final ms = results[i < results.length ? i++ : results.length - 1];
      if (ms == null) throw Exception('unreachable');
      return Duration(milliseconds: ms);
    },
  );
}

void main() {
  group('ConnectionMonitor', () {
    Future<void> settle(WidgetTester tester, [int seconds = 11]) async {
      await tester.pump(Duration(seconds: seconds));
    }

    testWidgets('a fast backend stays good and shows nothing', (tester) async {
      final monitor = monitorFor([120])..start();
      await tester.pump();
      expect(monitor.quality, ConnectionQuality.good);
      expect(monitor.bannerVisible, isFalse);
      monitor.dispose();
    });

    testWidgets('a slow answer is a poor connection', (tester) async {
      final monitor = monitorFor([2500])..start();
      await tester.pump();
      expect(monitor.quality, ConnectionQuality.poor);
      expect(monitor.bannerVisible, isTrue);
      monitor.dispose();
    });

    testWidgets('one failure is poor, two in a row are offline', (tester) async {
      final monitor = monitorFor([100, null, null])..start();
      await tester.pump();
      expect(monitor.quality, ConnectionQuality.good);

      await settle(tester); // second probe fails
      expect(monitor.quality, ConnectionQuality.poor);

      await settle(tester, 3); // quick retry fails too
      expect(monitor.quality, ConnectionQuality.offline);
      monitor.dispose();
    });

    testWidgets('recovers, and only once the link is clearly fast', (
      tester,
    ) async {
      final monitor = monitorFor([3000, 1500, 300])..start();
      await tester.pump();
      expect(monitor.quality, ConnectionQuality.poor);

      await settle(tester); // 1.5 s: better than 2 s but not yet trusted
      expect(monitor.quality, ConnectionQuality.poor);

      await settle(tester);
      expect(monitor.quality, ConnectionQuality.good);
      monitor.dispose();
    });

    testWidgets('dismissing hides the banner until the problem changes', (
      tester,
    ) async {
      final monitor = monitorFor([3000, 3000, null, null, 100])..start();
      await tester.pump();
      monitor.dismiss();
      expect(monitor.bannerVisible, isFalse);

      await settle(tester); // still poor: stays dismissed
      expect(monitor.quality, ConnectionQuality.poor);
      expect(monitor.bannerVisible, isFalse);

      await settle(tester); // fails, then the quick retry fails: offline, a
      // new problem, so the banner shows again
      expect(monitor.quality, ConnectionQuality.offline);
      expect(monitor.bannerVisible, isTrue);

      monitor.dismiss();
      await settle(tester, 3); // back online
      expect(monitor.quality, ConnectionQuality.good);
      expect(monitor.bannerVisible, isFalse);
      monitor.dispose();
    });
  });

  group('ConnectionBannerOverlay', () {
    Future<ConnectionMonitor> pump(WidgetTester tester, List<int?> results) async {
      final monitor = monitorFor(results);
      await tester.pumpWidget(
        ChangeNotifierProvider<ConnectionMonitor>.value(
          value: monitor,
          child: MaterialApp(
            builder: (context, child) => ConnectionBannerOverlay(child: child!),
            home: const Scaffold(body: Center(child: Text('map'))),
          ),
        ),
      );
      monitor.start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return monitor;
    }

    testWidgets('red banner when offline, dismissable', (tester) async {
      final monitor = await pump(tester, [null, null]);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text("You're offline"), findsOneWidget);
      expect(tester.getTopLeft(find.text("You're offline")).dy, greaterThan(0));

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.getTopLeft(find.text("You're offline")).dy,
        lessThan(0),
        reason: 'slid off screen',
      );
      monitor.dispose();
    });

    testWidgets('yellow banner on a poor connection', (tester) async {
      final monitor = await pump(tester, [4000]);
      expect(find.text('Poor connection'), findsOneWidget);
      final material = tester.widget<Material>(
        find
            .ancestor(
              of: find.text('Poor connection'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, const Color(0xFFFFC928));
      monitor.dispose();
    });
  });
}
