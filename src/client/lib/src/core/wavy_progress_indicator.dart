import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// The Material 3 Expressive linear progress bar: a wave for what is done, a
/// straight track for what is left, a gap between them and a dot at the end of
/// the track. Flutter's own [LinearProgressIndicator] is the flat one.
///
/// The wave travels along the bar while it is showing; with animations turned
/// off (see [AppMotion.of]) it holds still. It flattens at both ends, as the
/// spec's does, so an empty or a finished bar is a plain line.
class WavyLinearProgressIndicator extends StatefulWidget {
  const WavyLinearProgressIndicator({
    super.key,
    required this.value,
    this.color,
    this.trackColor,
    this.semanticsLabel,
  });

  /// How much is done, from 0 to 1.
  final double value;

  /// The wave and the stop dot; the theme's primary by default.
  final Color? color;

  /// The unfinished part; the theme's secondary container by default.
  final Color? trackColor;

  final String? semanticsLabel;

  /// The spec's numbers, in logical pixels.
  static const double thickness = 4;
  static const double amplitude = 3;
  static const double wavelength = 40;
  static const double gap = 4;
  static const double stopDotSize = 4;
  static const double height = thickness + 2 * amplitude;

  @override
  State<WavyLinearProgressIndicator> createState() =>
      _WavyLinearProgressIndicatorState();
}

class _WavyLinearProgressIndicatorState
    extends State<WavyLinearProgressIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: AppMotion.wave,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A looping animation is not a transition, so it is stopped outright for
    // anyone who asked for none, and not left running for tests to wait on.
    if (MediaQuery.disableAnimationsOf(context)) {
      _phase.stop();
    } else if (!_phase.isAnimating) {
      _phase.repeat();
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = widget.value.clamp(0.0, 1.0);
    return Semantics(
      label: widget.semanticsLabel,
      value: '${(value * 100).round()}%',
      child: SizedBox(
        height: WavyLinearProgressIndicator.height,
        width: double.infinity,
        child: CustomPaint(
          painter: WavyProgressPainter(
            value: value,
            phase: _phase,
            color: widget.color ?? scheme.primary,
            trackColor: widget.trackColor ?? scheme.secondaryContainer,
          ),
        ),
      ),
    );
  }
}

/// Paints the bar; split out so a test can look at the geometry.
class WavyProgressPainter extends CustomPainter {
  WavyProgressPainter({
    required this.value,
    required Animation<double> phase,
    required this.color,
    required this.trackColor,
  }) : _phase = phase,
       super(repaint: phase);

  final double value;
  final Animation<double> _phase;
  final Color color;
  final Color trackColor;

  /// 0 at the very start and end, 1 through the middle: a wave needs room.
  static double amplitudeFactor(double value) =>
      math.min(1.0, value / 0.1) * math.min(1.0, (1 - value) / 0.05);

  /// Height of the wave above/below the centre line at [x], in logical pixels.
  double waveOffset(double x, double startX) {
    final amplitude =
        WavyLinearProgressIndicator.amplitude * amplitudeFactor(value);
    final cycles =
        (x - startX) / WavyLinearProgressIndicator.wavelength - _phase.value;
    return amplitude * math.sin(2 * math.pi * cycles);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const thickness = WavyLinearProgressIndicator.thickness;
    const radius = thickness / 2;
    final centerY = size.height / 2;
    final startX = radius;
    final endX = size.width - radius;
    final activeEnd = startX + (endX - startX) * value;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;

    // What is left: a straight track after the gap, with a dot at its end.
    final trackStart = activeEnd + thickness + WavyLinearProgressIndicator.gap;
    if (value < 1 && trackStart < endX) {
      canvas.drawLine(
        Offset(trackStart, centerY),
        Offset(endX, centerY),
        stroke..color = trackColor,
      );
      canvas.drawCircle(
        Offset(endX, centerY),
        WavyLinearProgressIndicator.stopDotSize / 2,
        Paint()..color = color,
      );
    }

    // What is done: the wave.
    if (value > 0) {
      final path = Path()..moveTo(startX, centerY + waveOffset(startX, startX));
      for (var x = startX + 1; x < activeEnd; x += 1) {
        path.lineTo(x, centerY + waveOffset(x, startX));
      }
      path.lineTo(activeEnd, centerY + waveOffset(activeEnd, startX));
      canvas.drawPath(path, stroke..color = color);
    } else {
      // Nothing yet: just the cap, so the bar reads as started.
      canvas.drawCircle(
        Offset(startX, centerY),
        radius,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(WavyProgressPainter old) =>
      old.value != value ||
      old.color != color ||
      old.trackColor != trackColor ||
      old._phase != _phase;
}
