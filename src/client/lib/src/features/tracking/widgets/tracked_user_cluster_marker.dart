import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'user_avatar.dart';

/// One person inside a [TrackedUserClusterMarker].
class ClusterMember {
  const ClusterMember({
    required this.id,
    required this.name,
    required this.avatarUrl,
    required this.isStale,
    required this.onTap,
    this.avatarBytes,
    this.isSelected = false,
  });

  final String id;
  final String name;
  final String avatarUrl;
  final bool isStale;

  /// Our own locally picked photo, which has no URL.
  final Uint8List? avatarBytes;

  /// Rings the face in the accent colour.
  final bool isSelected;

  /// Selects this member, mirroring [TrackedUserMarker]'s own onTap so the
  /// drawer shows that person's stats just like a lone marker would.
  final VoidCallback onTap;
}

/// A Life360-style pin: one face per person in a white pill whose short tail
/// ends in a dot on the location, so the exact spot is always readable. Used
/// for a lone user (one face) and for a group of users who are close together.
///
/// The members' faces overlap inside a white pill whose short tail ends in a
/// dot on the shared location. Tapping a face selects that member; tapping
/// the rest of the bubble (or the "+N" overflow face) zooms the map in until
/// the group separates into individual markers.
class TrackedUserClusterMarker extends StatelessWidget {
  const TrackedUserClusterMarker({
    super.key,
    required this.members,
    required this.onTap,
    required this.accentColor,
  });

  final List<ClusterMember> members;
  final VoidCallback onTap;

  /// The location dot at the tail's tip.
  final Color accentColor;

  /// At most this many faces are drawn; the rest fold into a "+N" face.
  static const int maxFaces = 3;
  static const double _faceSize = 42;
  static const double _faceStep = 30; // faces overlap by 12 px
  static const double _ring = 1.5;
  static const double _padding = 3;
  // The tail runs to the dot's centre, so the two read as one pin.
  static const double _tailHeight = 13;
  static const double _tailHalfWidth = 8;
  static const double _dotSize = 14;
  static const double _bubbleHeight = _faceSize + _padding * 2;

  static int _slotCountFor(int memberCount) =>
      memberCount > maxFaces ? maxFaces + 1 : memberCount;

  /// The footprint this widget needs in a flutter_map `Marker`; place it with
  /// [alignmentFor] so the dot — not the bubble — sits on the location.
  static double widthFor(int memberCount) {
    final slots = _slotCountFor(memberCount);
    return _padding * 2 + _faceSize + (slots - 1) * _faceStep;
  }

  static const double height = _bubbleHeight + _tailHeight + _dotSize / 2;

  static Alignment alignmentFor(int memberCount) =>
      Marker.computePixelAlignment(
        width: widthFor(memberCount),
        height: height,
        left: widthFor(memberCount) / 2,
        top: height - _dotSize / 2,
      );

  @override
  Widget build(BuildContext context) {
    final width = widthFor(members.length);
    final faces = members.length > maxFaces ? maxFaces : members.length;
    final overflow = members.length - faces;
    final allStale = members.every((m) => m.isStale);

    // Faces are stacked right-to-left so the leftmost one is on top — both
    // visually and for hit testing.
    final slots = <Widget>[
      if (overflow > 0)
        _slot(
          faces,
          GestureDetector(
            onTap: onTap,
            child: _OverflowFace(count: overflow, size: _faceSize),
          ),
        ),
      for (var i = faces - 1; i >= 0; i--)
        _slot(
          i,
          GestureDetector(
            onTap: members[i].onTap,
            child: UserAvatar(
              userId: members[i].id,
              name: members[i].name,
              avatarUrl: members[i].avatarUrl,
              imageBytes: members[i].avatarBytes,
              size: _faceSize,
              ringColor: members[i].isSelected ? accentColor : Colors.white,
              ringWidth: _ring,
              dimmed: members[i].isStale,
            ),
          ),
        ),
    ];

    return Tooltip(
      message: members.map((m) => m.name).join(', '),
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: 0,
                width: width,
                height: _bubbleHeight + _tailHeight,
                child: CustomPaint(
                  painter: _BubblePainter(
                    bubbleHeight: _bubbleHeight,
                    tailHeight: _tailHeight,
                    tailHalfWidth: _tailHalfWidth,
                  ),
                ),
              ),
              ...slots,
              Positioned(
                left: (width - _dotSize) / 2,
                bottom: 0,
                child: _LocationDot(
                  size: _dotSize,
                  color: allStale ? Colors.grey.shade600 : accentColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _slot(int index, Widget child) => Positioned(
    left: _padding + index * _faceStep,
    top: _padding,
    child: child,
  );
}

class _OverflowFace extends StatelessWidget {
  const _OverflowFace({required this.count, required this.size});

  final int count;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF2B3134),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        '+$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LocationDot extends StatelessWidget {
  const _LocationDot({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
    );
  }
}

/// A fully rounded pill with a short tail cut into its bottom edge, painted
/// as one path so fill and shadow never double up at the seam.
class _BubblePainter extends CustomPainter {
  const _BubblePainter({
    required this.bubbleHeight,
    required this.tailHeight,
    required this.tailHalfWidth,
  });

  final double bubbleHeight;
  final double tailHeight;
  final double tailHalfWidth;

  Path _buildPath(Size size) {
    final r = bubbleHeight / 2;
    final w = size.width;
    final cx = w / 2;
    return Path()
      ..moveTo(r, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w - r, bubbleHeight), radius: Radius.circular(r))
      ..lineTo(cx + tailHalfWidth, bubbleHeight)
      ..quadraticBezierTo(
        cx + 2,
        bubbleHeight + tailHeight * 0.6,
        cx,
        bubbleHeight + tailHeight,
      )
      ..quadraticBezierTo(
        cx - 2,
        bubbleHeight + tailHeight * 0.6,
        cx - tailHalfWidth,
        bubbleHeight,
      )
      ..lineTo(r, bubbleHeight)
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r))
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _buildPath(size);
    canvas.drawShadow(path, Colors.black, 4, false);
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) =>
      oldDelegate.bubbleHeight != bubbleHeight ||
      oldDelegate.tailHeight != tailHeight ||
      oldDelegate.tailHalfWidth != tailHalfWidth;
}
