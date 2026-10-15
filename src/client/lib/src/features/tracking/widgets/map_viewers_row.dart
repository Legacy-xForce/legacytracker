import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/models/map_viewer.dart';
import 'user_avatar.dart';

/// Who has the live map open right now, as overlapping faces in a pill beside
/// the sharing pill. Nothing shows while nobody does.
class MapViewersRow extends StatelessWidget {
  const MapViewersRow({
    super.key,
    required this.viewers,
    required this.selfId,
    this.selfAvatarBytes,
  });

  /// At most this many circles, so the row never runs into the map controls:
  /// with more viewers, the last circle counts the rest.
  static const maxCircles = 3;
  static const faceSize = 32.0;
  static const _overlap = 10.0;
  static const _padding = 3.0;

  final List<MapViewer> viewers;
  final String selfId;

  /// Our own locally picked photo, as on our marker.
  final Uint8List? selfAvatarBytes;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: animation,
          alignment: Alignment.centerLeft,
          child: child,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      child: viewers.isEmpty
          ? const SizedBox.shrink(key: ValueKey('nobody'))
          : Padding(
              key: const ValueKey('viewers'),
              padding: const EdgeInsets.only(left: 8),
              child: _pill(context),
            ),
    );
  }

  Widget _pill(BuildContext context) {
    final theme = Theme.of(context);
    final background = theme.colorScheme.surfaceContainerHigh;
    // We're always first, then everyone else in the order they started
    // looking.
    final ordered = [
      ...viewers.where((viewer) => viewer.id == selfId),
      ...viewers.where((viewer) => viewer.id != selfId),
    ];
    final overflow = ordered.length > maxCircles;
    final faces = overflow ? ordered.take(maxCircles - 1) : ordered;
    final circles = <Widget>[
      for (final viewer in faces)
        _PopIn(
          key: ValueKey(viewer.id),
          child: UserAvatar(
            userId: viewer.id,
            name: viewer.name,
            imageBytes: viewer.id == selfId ? selfAvatarBytes : null,
            size: faceSize,
            ringColor: background,
            ringWidth: 2,
          ),
        ),
      if (overflow)
        _MoreCircle(
          key: const ValueKey('more'),
          count: ordered.length - faces.length,
          ringColor: background,
        ),
    ];
    final names = [
      for (final viewer in ordered) viewer.id == selfId ? 'you' : viewer.name,
    ].join(', ');

    return Semantics(
      label: 'Viewing the map: $names',
      excludeSemantics: true,
      child: Material(
        color: background,
        elevation: 4,
        shadowColor: Colors.black54,
        shape: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.all(_padding),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: faceSize + (circles.length - 1) * (faceSize - _overlap),
              height: faceSize,
              child: Stack(
                children: [
                  for (var i = 0; i < circles.length; i++)
                    Positioned(
                      key: circles[i].key,
                      left: i * (faceSize - _overlap),
                      top: 0,
                      child: circles[i],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Grows a face in when it first appears.
class _PopIn extends StatelessWidget {
  const _PopIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      builder: (context, value, child) =>
          Transform.scale(scale: value, child: child),
      child: child,
    );
  }
}

/// "+N" for the viewers who don't get a face.
class _MoreCircle extends StatelessWidget {
  const _MoreCircle({super.key, required this.count, required this.ringColor});

  final int count;
  final Color ringColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: MapViewersRow.faceSize,
      height: MapViewersRow.faceSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(color: ringColor, width: 2),
      ),
      child: Text(
        '+$count',
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
