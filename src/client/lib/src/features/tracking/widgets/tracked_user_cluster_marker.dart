import 'package:flutter/material.dart';

/// A Life360-style "group" marker: shown instead of individual
/// [TrackedUserMarker]s when several users are close enough together on
/// screen that their pins would otherwise overlap and become indistinguishable.
/// Displays a small stack of the members' avatars plus a count badge; tapping
/// it zooms the map in until the group separates into individual markers.
class TrackedUserClusterMarker extends StatelessWidget {
  const TrackedUserClusterMarker({
    super.key,
    required this.avatarUrls,
    required this.names,
    required this.isAnyMoving,
    required this.isAllStale,
    this.onTap,
    required this.ringColor,
    required this.badgeColor,
  });

  final List<String> avatarUrls;
  final List<String> names;
  final bool isAnyMoving;
  final bool isAllStale;
  final VoidCallback? onTap;
  final Color ringColor;
  final Color badgeColor;

  /// The footprint this widget needs when placed in a flutter_map `Marker`,
  /// matched to [TrackedUserMarker] so the two can freely swap in the layer.
  static const double width = 152;
  static const double height = 168;

  /// At most this many avatars are drawn in the face pile; the rest are
  /// folded into the count badge.
  static const int maxFaces = 3;
  static const double _faceSize = 40;
  static const double _faceOverlap = 16;

  @override
  Widget build(BuildContext context) {
    final displayRingColor = isAllStale ? Colors.grey.shade500 : ringColor;
    final displayBadgeColor = isAllStale ? Colors.grey.shade700 : badgeColor;
    final faces = names.length > maxFaces ? maxFaces : names.length;
    final pileWidth = _faceSize + (faces - 1) * (_faceSize - _faceOverlap);

    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: names.join(', '),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (isAnyMoving)
              Container(
                width: pileWidth + 22,
                height: _faceSize + 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: displayRingColor.withValues(alpha: 0.16),
                ),
              ),
            SizedBox(
              width: pileWidth,
              height: _faceSize,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < faces; i++)
                    Positioned(
                      left: i * (_faceSize - _faceOverlap),
                      child: Container(
                        width: _faceSize,
                        height: _faceSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: CircleAvatar(
                          backgroundColor: displayRingColor,
                          backgroundImage: avatarUrls[i].isNotEmpty
                              ? NetworkImage(avatarUrls[i])
                              : null,
                          child: avatarUrls[i].isEmpty && names[i].isNotEmpty
                              ? Text(
                                  names[i].characters.first.toUpperCase(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Positioned(
              right: -6,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: displayBadgeColor,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  '${names.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
