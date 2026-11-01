import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/core/theme.dart';
import 'package:legacytracker/src/core/wavy_progress_indicator.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    double value, {
    bool disableAnimations = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildThemeFor(AppThemeId.catppuccinMocha),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: WavyLinearProgressIndicator(value: value),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a half-done bar is the spec height and reads as 50%', (
    tester,
  ) async {
    await pump(tester, 0.5);
    expect(
      tester.getSize(find.byType(WavyLinearProgressIndicator)).height,
      WavyLinearProgressIndicator.height,
    );
    expect(
      tester.getSemantics(find.byType(WavyLinearProgressIndicator)),
      matchesSemantics(value: '50%'),
    );
  });

  testWidgets('the wave travels while animations are on', (tester) async {
    await pump(tester, 0.5);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('it holds still when animations are turned off', (tester) async {
    await pump(tester, 0.5, disableAnimations: true);
    expect(tester.hasRunningAnimations, isFalse);
  });

  test('the wave fades out at the ends, so empty and done are plain lines', () {
    expect(WavyProgressPainter.amplitudeFactor(0), 0);
    expect(WavyProgressPainter.amplitudeFactor(1), 0);
    expect(WavyProgressPainter.amplitudeFactor(0.5), 1);
    expect(WavyProgressPainter.amplitudeFactor(0.05), closeTo(0.5, 1e-9));
  });

  test('the wave is a sine of the spec wavelength and amplitude', () {
    final phase = AlwaysStoppedAnimation<double>(0);
    final painter = WavyProgressPainter(
      value: 0.5,
      phase: phase,
      color: Colors.white,
      trackColor: Colors.grey,
    );
    expect(painter.waveOffset(2, 2), closeTo(0, 1e-9));
    expect(
      painter.waveOffset(2 + WavyLinearProgressIndicator.wavelength / 4, 2),
      closeTo(WavyLinearProgressIndicator.amplitude, 1e-9),
    );
    expect(
      painter.waveOffset(2 + WavyLinearProgressIndicator.wavelength, 2),
      closeTo(0, 1e-9),
    );
  });
}
