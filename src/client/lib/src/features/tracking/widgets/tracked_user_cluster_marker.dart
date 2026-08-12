import 'package:flutter/material.dart';

/// A Life360-style "group" marker: shown instead of individual
/// [TrackedUserMarker]s when several users are close enough together on
/// screen that their pins would otherwise overlap and become indistinguishable.
/// Displays the members' avatars side by side inside a single speech-bubble
/// shaped pin, its tail pointing at the shared location; tapping the bubble
/// zooms the map in until the group separates into individual markers, while
/// tapping one avatar selects that member directly.
class TrackedUserClusterMarker extends StatelessWidget {
  const TrackedUserClusterMarker({
    super.key,
    required this.avatarUrls,
    required this.names,
    required this.isAllStale,
    this.onTap,
    required this.onMemberTap,
    required this.ringColor,
    required this.badgeColor,
  });

  final List<String> avatarUrls;
  final List<String> names;
  final bool isAllStale;

  /// Tapping the bubble background, or the overflow "+N" face, zooms the map
  /// to separate the group instead of picking any one member.
  final VoidCallback? onTap;

  /// Tapping an individual face selects that member, one callback per index
  /// in [avatarUrls]/[names], mirroring [TrackedUserMarker]'s own onTap so
  /// the drawer shows that person's stats just like a lone marker would.
  final List<VoidCallback> onMemberTap;
  final Color ringColor;
  final Color badgeColor;

  /// At most this many avatars are drawn side by side; the rest are folded
  /// into a "+N" overflow face.
  static const int maxFaces = 3;
  static const double _faceSize = 44;
  static const double _faceGap = 6;
  static const double _bubblePadding = 10;
  static const double _cornerRadius = 30;
  static const double _tailHalfWidth = 16;
  static const double _tailHeight = 30;
  static const double _bubbleHeight = _bubblePadding * 2 + _faceSize;

  /// The number of faces actually drawn (real members, capped at
  /// [maxFaces], plus one more slot for the "+N" overflow face when needed).
  static int _slotCountFor(int memberCount) {
    final faces = memberCount > maxFaces ? maxFaces : memberCount;
    final hasOverflow = memberCount > faces;
    return faces + (hasOverflow ? 1 : 0);
  }

  /// The footprint this widget needs when placed in a flutter_map `Marker`
  /// for a cluster of [memberCount] members. Pair with
  /// `Alignment.bottomCenter` when placing the `Marker` so the tail's tip —
  /// not the bubble body — lands exactly on the location.
  static double widthFor(int memberCount) {
    final slots = _slotCountFor(memberCount);
    return _bubblePadding * 2 + slots * _faceSize + (slots - 1) * _faceGap;
  }

  static const double height = _bubbleHeight + _tailHeight;

  @override
  Widget build(BuildContext context) {
    final displayRingColor = isAllStale ? Colors.grey.shade500 : ringColor;
    final displayBadgeColor = isAllStale ? Colors.grey.shade700 : badgeColor;
    final faces = names.length > maxFaces ? maxFaces : names.length;
    final overflow = names.length - faces;
    final bubbleWidth = widthFor(names.length);

    // A single speech-bubble outline (rounded rect fused with a triangular
    // tail) drawn as one path, so no seam border shows where the tail meets
    // the body — the avatars then sit inside it in a plain row.
    return Tooltip(
      message: names.join(', '),
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: bubbleWidth,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _BubblePainter(
                    bubbleWidth: bubbleWidth,
                    bubbleHeight: _bubbleHeight,
                    cornerRadius: _cornerRadius,
                    tailHalfWidth: _tailHalfWidth,
                    tailHeight: _tailHeight,
                  ),
                ),
              ),
              Positioned(
                left: _bubblePadding,
                top: _bubblePadding,
                child: Row(
                  children: [
                    for (var i = 0; i < faces; i++) ...[
                      if (i > 0) const SizedBox(width: _faceGap),
                      GestureDetector(
                        onTap: onMemberTap[i],
                        child: _Face(
                          color: displayRingColor,
                          avatarUrl: avatarUrls[i],
                          initial: names[i].isNotEmpty
                              ? names[i].characters.first.toUpperCase()
                              : '',
                          size: _faceSize,
                        ),
                      ),
                    ],
                    if (overflow > 0) ...[
                      const SizedBox(width: _faceGap),
                      GestureDetector(
                        onTap: onTap,
                        child: Container(
                          width: _faceSize,
                          height: _faceSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: displayBadgeColor,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '+$overflow',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single avatar circle: photo if available, otherwise the member's
/// initial on a colored background.
class _Face extends StatelessWidget {
  const _Face({
    required this.color,
    required this.avatarUrl,
    required this.initial,
    required this.size,
  });

  final Color color;
  final String avatarUrl;
  final String initial;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircleAvatar(
        backgroundColor: color,
        backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
        child: avatarUrl.isEmpty && initial.isNotEmpty
            ? Text(
                initial,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.4,
                  fontWeight: FontWeight.w600,
                ),
              )
            : null,
      ),
    );
  }
}

/// Paints the fused speech-bubble outline: a rounded rect body with a
/// triangular tail cut directly into its bottom edge, as one continuous
/// path so the fill and stroke never double up at the seam.
class _BubblePainter extends CustomPainter {
  const _BubblePainter({
    required this.bubbleWidth,
    required this.bubbleHeight,
    required this.cornerRadius,
    required this.tailHalfWidth,
    required this.tailHeight,
  });

  final double bubbleWidth;
  final double bubbleHeight;
  final double cornerRadius;
  final double tailHalfWidth;
  final double tailHeight;

  Path _buildPath() {
    final r = cornerRadius;
    final centerX = bubbleWidth / 2;
    final tailLeft = centerX - tailHalfWidth;
    final tailRight = centerX + tailHalfWidth;

    return Path()
      ..moveTo(r, 0)
      ..lineTo(bubbleWidth - r, 0)
      ..arcToPoint(Offset(bubbleWidth, r), radius: Radius.circular(r))
      ..lineTo(bubbleWidth, bubbleHeight - r)
      ..arcToPoint(
        Offset(bubbleWidth - r, bubbleHeight),
        radius: Radius.circular(r),
      )
      ..lineTo(tailRight, bubbleHeight)
      ..lineTo(centerX, bubbleHeight + tailHeight)
      ..lineTo(tailLeft, bubbleHeight)
      ..lineTo(r, bubbleHeight)
      ..arcToPoint(Offset(0, bubbleHeight - r), radius: Radius.circular(r))
      ..lineTo(0, r)
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r))
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _buildPath();

    canvas.save();
    canvas.translate(0, 2);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.restore();

    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) {
    return oldDelegate.bubbleWidth != bubbleWidth ||
        oldDelegate.bubbleHeight != bubbleHeight ||
        oldDelegate.cornerRadius != cornerRadius ||
        oldDelegate.tailHalfWidth != tailHalfWidth ||
        oldDelegate.tailHeight != tailHeight;
  }
}
