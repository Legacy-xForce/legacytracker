import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Saturated enough to read on light map tiles and the dark UI alike, and
/// all dark enough for a white initial.
const _palette = <Color>[
  Color(0xFF1E88E5), // blue
  Color(0xFF8E24AA), // purple
  Color(0xFFF4511E), // deep orange
  Color(0xFF00897B), // teal
  Color(0xFFD81B60), // pink
  Color(0xFF43A047), // green
  Color(0xFF3949AB), // indigo
  Color(0xFFEF6C00), // orange
  Color(0xFF6D4C41), // brown
  Color(0xFF00838F), // cyan
];

/// A stable color per user, so the same person reads the same on their
/// marker, inside a group bubble and in the people list.
Color userColor(String userId) {
  // FNV-1a: cheap, and stable across runs unlike String.hashCode.
  var hash = 0x811c9dc5;
  for (final unit in userId.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return _palette[hash % _palette.length];
}

String userInitial(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
}

/// A user's photo, or their initial on their own color.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.userId,
    required this.name,
    this.avatarUrl = '',
    this.imageBytes,
    this.size = 44,
    this.ringColor,
    this.ringWidth = 0,
    this.dimmed = false,
  });

  final String userId;
  final String name;
  final String avatarUrl;

  /// A local photo (our own picked avatar) takes precedence over [avatarUrl].
  final Uint8List? imageBytes;
  final double size;
  final Color? ringColor;
  final double ringWidth;

  /// Greyed out for users we haven't heard from in a while.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = imageBytes != null
        ? MemoryImage(imageBytes!)
        : avatarUrl.isNotEmpty
        ? NetworkImage(avatarUrl)
        : null;
    final color = dimmed ? Colors.grey.shade600 : userColor(userId);

    Widget avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        image: image == null
            ? null
            : DecorationImage(image: image, fit: BoxFit.cover),
        border: ringWidth > 0 && ringColor != null
            ? Border.all(color: ringColor!, width: ringWidth)
            : null,
      ),
      alignment: Alignment.center,
      child: image == null
          ? Text(
              userInitial(name),
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.42,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            )
          : null,
    );

    if (dimmed && image != null) {
      avatar = ColorFiltered(
        colorFilter: const ColorFilter.mode(Colors.grey, BlendMode.saturation),
        child: avatar,
      );
    }
    return avatar;
  }
}
