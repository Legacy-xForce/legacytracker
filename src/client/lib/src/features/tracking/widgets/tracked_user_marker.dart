import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Normalizes bearing to 0-360 range.
double normalizeBearing(double bearing) {
  final normalized = bearing % 360.0;
  return normalized < 0 ? normalized + 360.0 : normalized;
}

/// The rich avatar/beam/badge marker used to represent a user's position on
/// the map, shared between live tracking and session replay so both render
/// identically instead of replay falling back to a plain dot.
class TrackedUserMarker extends StatefulWidget {
  const TrackedUserMarker({
    super.key,
    required this.name,
    this.avatarUrl = '',
    required this.speedKmh,
    required this.isMoving,
    this.heading,
    this.isStale = false,
    this.batteryLevel,
    this.isCharging = false,
    this.isSelected = false,
    this.onTap,
    required this.tooltipMessage,
    required this.beamColor,
    required this.ringColor,
    required this.badgeColor,
  });

  final String name;
  final String avatarUrl;
  final double speedKmh;
  final bool isMoving;
  final double? heading;
  final bool isStale;
  final int? batteryLevel;
  final bool isCharging;
  final bool isSelected;
  final VoidCallback? onTap;
  final String tooltipMessage;
  final Color beamColor;
  final Color ringColor;
  final Color badgeColor;

  /// The footprint this widget needs when placed in a flutter_map `Marker`.
  static const double width = 152;
  static const double height = 168;

  @override
  State<TrackedUserMarker> createState() => _TrackedUserMarkerState();
}

class _TrackedUserMarkerState extends State<TrackedUserMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant TrackedUserMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    if (widget.isMoving) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      if (_pulseController.isAnimating) {
        _pulseController.stop();
      }
      _pulseController.value = 0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  IconData _batteryIcon(int? level, bool isCharging) {
    if (isCharging) return Icons.battery_charging_full_rounded;
    if (level == null) return Icons.battery_unknown_rounded;
    if (level >= 90) return Icons.battery_full_rounded;
    if (level >= 70) return Icons.battery_5_bar_rounded;
    if (level >= 55) return Icons.battery_4_bar_rounded;
    if (level >= 40) return Icons.battery_3_bar_rounded;
    if (level >= 25) return Icons.battery_2_bar_rounded;
    if (level >= 10) return Icons.battery_1_bar_rounded;
    return Icons.battery_alert_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final heading = widget.heading == null
        ? null
        : normalizeBearing(widget.heading!);
    final displayBeamColor = widget.isStale
        ? Colors.grey.shade500
        : widget.beamColor;
    final displayRingColor = widget.isStale
        ? Colors.grey.shade500
        : widget.ringColor;
    final displayBadgeColor = widget.isStale
        ? Colors.grey.shade700
        : widget.badgeColor;
    final batteryLevel = widget.batteryLevel?.clamp(0, 100).toInt();
    final batteryIcon = _batteryIcon(batteryLevel, widget.isCharging);

    return GestureDetector(
      onTap: widget.onTap,
      child: Tooltip(
        message: widget.tooltipMessage,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(
            end: widget.isSelected ? 1.18 : (widget.isMoving ? 1.08 : 1.0),
          ),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          builder: (context, scale, child) {
            return Transform.scale(scale: scale, child: child);
          },
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (heading != null && widget.isMoving)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedRotation(
                      turns: heading / 360.0,
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      child: CustomPaint(
                        painter: _HeadingBeamPainter(beamColor: displayBeamColor),
                      ),
                    ),
                  ),
                ),
              if (widget.isMoving)
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final t = Curves.easeOut.transform(_pulseController.value);
                    return Container(
                      width: 58 + (22 * t),
                      height: 58 + (22 * t),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: displayBeamColor.withValues(alpha: 0.22 * (1 - t)),
                      ),
                    );
                  },
                ),
              ColorFiltered(
                colorFilter: widget.isStale
                    ? const ColorFilter.matrix(<double>[
                        0.2126,
                        0.7152,
                        0.0722,
                        0,
                        0,
                        0.2126,
                        0.7152,
                        0.0722,
                        0,
                        0,
                        0.2126,
                        0.7152,
                        0.0722,
                        0,
                        0,
                        0,
                        0,
                        0,
                        1,
                        0,
                      ])
                    : const ColorFilter.mode(
                        Colors.transparent,
                        BlendMode.srcOver,
                      ),
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.isMoving ? Colors.teal.shade600 : Colors.teal,
                    border: Border.all(color: displayRingColor, width: 4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.white,
                    backgroundImage: widget.avatarUrl.isNotEmpty
                        ? NetworkImage(widget.avatarUrl)
                        : null,
                    child: widget.avatarUrl.isEmpty && widget.name.isNotEmpty
                        ? Text(widget.name.characters.first.toUpperCase())
                        : null,
                  ),
                ),
              ),
              Positioned(
                top: 48,
                right: 18,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: displayBadgeColor,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.speed_rounded,
                        size: 12,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${widget.speedKmh.round()} km/h',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (batteryLevel != null)
                Positioned(
                  top: 116,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: displayBadgeColor,
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(batteryIcon, size: 12, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(
                            '$batteryLevel%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeadingBeamPainter extends CustomPainter {
  _HeadingBeamPainter({required this.beamColor});

  final Color beamColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 4);
    final outerRadius = size.height * 0.46;

    // 56° total cone (±28° from the upward axis)
    const halfAngle = 28.0 * math.pi / 180.0;
    const upAngle = -math.pi / 2;

    final arcRect = Rect.fromCircle(center: center, radius: outerRadius);
    final conePath = ui.Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(arcRect, upAngle - halfAngle, halfAngle * 2, false)
      ..close();

    // Blurred glow layer drawn first to feather the straight edges
    final glowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = beamColor.withValues(alpha: 0.12)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    canvas.drawPath(conePath, glowPaint);

    // Main beam: radial gradient from ~50% opacity at user position to 0% at outer arc
    final gradientPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: [
          beamColor.withValues(alpha: 0.50),
          beamColor.withValues(alpha: 0.0),
        ],
      ).createShader(arcRect);
    canvas.drawPath(conePath, gradientPaint);
  }

  @override
  bool shouldRepaint(covariant _HeadingBeamPainter oldDelegate) {
    return oldDelegate.beamColor != beamColor;
  }
}
