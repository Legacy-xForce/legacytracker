import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'user_avatar.dart';

/// Accent used by the map markers, matching the app's teal/blue accents.
const markerAccentColor = Color(0xFF0985FB);

/// A bitmap ready to be added to the Mapbox style as a symbol image.
class MarkerImage {
  const MarkerImage({
    required this.id,
    required this.width,
    required this.height,
    required this.scale,
    required this.png,
    this.anchorOffsetY = 0,
  });

  final String id;

  /// Physical pixel size. Divide by [scale] for the logical size.
  final int width;
  final int height;

  /// Device pixel ratio the image was rendered at. Mapbox divides the icon by
  /// this, so a 2x bitmap stays sharp without changing its logical size.
  final double scale;

  /// Encoded PNG bytes. Mapbox decodes these natively (Android
  /// `BitmapFactory`, iOS `UIImage`); raw RGBA is not accepted here.
  final Uint8List png;

  /// Downward shift applied with a bottom anchor so the tail dot, not the
  /// image edge, sits on the coordinate.
  final double anchorOffsetY;
}

/// One person drawn on the map. Mirrors the web client's `PeerMarker`: an
/// avatar in a ring, a speed badge while moving and a battery badge below.
class MarkerPerson {
  const MarkerPerson({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    this.avatarBytes,
    this.isStale = false,
    this.isSelected = false,
    this.isSelf = false,
    this.isMoving = false,
    this.speedKmh = 0,
    this.batteryLevel,
    this.isCharging = false,
  });

  final String id;
  final String name;
  final String avatarUrl;
  final Uint8List? avatarBytes;
  final bool isStale;
  final bool isSelected;

  /// Own marker: the ring and badges use the accent colour.
  final bool isSelf;
  final bool isMoving;
  final double speedKmh;
  final int? batteryLevel;
  final bool isCharging;
}

/// Builds the bitmap icons rendered through Mapbox point annotations.
///
/// Icons are cached by a deterministic id; callers add each id to the style
/// once and then only update annotation geometry/rotation as markers move.
/// Avatar downloads happen in the background: until one resolves the marker
/// shows the person's initial, and [notifyListeners] fires so the caller can
/// rebuild with the photo.
class MarkerIconFactory extends ChangeNotifier {
  static const double pixelRatio = 2.0;
  static const int _maxCachedIcons = 256;

  final Map<String, MarkerImage> _icons = {};
  final Map<String, ui.Image> _avatars = {};
  final Set<String> _avatarPending = {};
  final Set<String> _avatarFailed = {};
  bool _disposed = false;

  MarkerImage? _cached(String id) {
    final image = _icons.remove(id);
    if (image != null) _icons[id] = image;
    return image;
  }

  void _store(MarkerImage image) {
    _icons[image.id] = image;
    while (_icons.length > _maxCachedIcons) {
      _icons.remove(_icons.keys.first);
    }
  }

  // PeerMarker geometry in logical pixels, copied from the web client. The
  // box is the heading beam's footprint and the avatar sits in its centre, so
  // the marker anchors on the person.
  static const _personWidth = 152.0;
  static const _personHeight = 168.0;
  static const _personCenter = Offset(76, 84);
  static const _personRingSize = 60.0;
  static const _personAvatarSize = 53.0;
  static const _badgeHeight = 20.0;
  static const _badgeIconSize = 12.0;
  static const _badgeFontSize = 10.0;
  static const _badgeGap = 4.0;
  static const _badgePadX = 8.0;

  static const _staleGrey = Color(0xFF9E9E9E);
  static const _badgeDark = Color(0xFF212121);
  static const _badgeSelf = Color(0xFF00695C);
  static const _badgeStale = Color(0xFF616161);

  /// The web client's person marker: the avatar inside a ring, a soft pulse and
  /// a speed badge while moving, and the battery badge below. Selection and
  /// motion scaling are applied by the caller as the annotation's icon size.
  Future<MarkerImage> personMarker(MarkerPerson person) async {
    // Badge text and cache id share one 5 km/h bucket: that bounds how often a
    // 304x336 bitmap is re-rendered (roughly twice a second at motorway speed)
    // while still matching the web's rounded readout closely.
    final speed = person.isMoving ? (person.speedKmh / 5).round() * 5 : 0;
    final id =
        'person-${_personToken(person)}'
        '-${person.isMoving ? speed : 'parked'}'
        '-${person.batteryLevel ?? '-'}'
        '${person.isCharging ? 'c' : ''}';
    final cached = _cached(id);
    if (cached != null) return cached;

    final avatar = _avatarFor(person);
    final ring = person.isStale
        ? _staleGrey
        : person.isSelf
        ? markerAccentColor
        : Colors.white;
    final badge = person.isStale
        ? _badgeStale
        : person.isSelf
        ? _badgeSelf
        : _badgeDark;

    return _render(_personWidth, _personHeight, (canvas) {
      final ringPath = Path()
        ..addOval(
          Rect.fromCircle(center: _personCenter, radius: _personRingSize / 2),
        );
      canvas.drawShadow(ringPath, Colors.black, 6, false);
      canvas.drawPath(ringPath, Paint()..color = ring);
      _drawRoundAvatar(
        canvas,
        person: person,
        image: avatar,
        center: _personCenter,
        size: _personAvatarSize,
      );

      if (person.isMoving) {
        _badge(
          canvas,
          icon: Icons.speed_rounded,
          text: '$speed km/h',
          right: _personWidth - 18,
          top: 48,
          background: badge,
        );
      }
      final battery = person.batteryLevel?.clamp(0, 100);
      if (battery != null) {
        _badge(
          canvas,
          icon: _batteryIcon(battery, person.isCharging),
          text: '$battery%',
          centerX: _personCenter.dx,
          top: 116,
          background: badge,
        );
      }
    }, id: id);
  }

  // ClusterMarker geometry, the same numbers the web client uses.
  static const _clusterFaceSize = 42.0;
  static const _clusterFaceStep = 30.0;
  static const _clusterPadding = 5.0;
  static const _clusterBubbleHeight = 52.0;
  static const _clusterTailHeight = 9.0;
  static const _clusterDotSize = 14.0;
  static const _clusterHeight =
      _clusterBubbleHeight + _clusterTailHeight + _clusterDotSize - 2;
  static const _clusterMaxFaces = 3;

  /// Several people close together: their faces in one white bubble with a
  /// tail dot on the shared location, as on the web.
  Future<MarkerImage> clusterMarker(List<MarkerPerson> members) async {
    final allStale = members.every((m) => m.isStale);
    final id = _liveId(members, allStale);
    final cached = _cached(id);
    if (cached != null) return cached;

    final faces = members.length > _clusterMaxFaces
        ? _clusterMaxFaces
        : members.length;
    final overflow = members.length - faces;
    final slots = members.length > _clusterMaxFaces
        ? _clusterMaxFaces + 1
        : members.length;
    final width =
        _clusterPadding * 2 + _clusterFaceSize + (slots - 1) * _clusterFaceStep;
    final dotCenterY = _clusterHeight - _clusterDotSize / 2;

    final avatarImages = <int, ui.Image?>{
      for (var i = 0; i < faces; i++) i: _avatarFor(members[i]),
    };

    return _render(
      width,
      _clusterHeight,
      (canvas) {
        final path = _bubblePath(
          width: width,
          bubbleHeight: _clusterBubbleHeight,
          tailHeight: _clusterTailHeight,
        );
        canvas.drawShadow(path, Colors.black, 4, false);
        canvas.drawPath(path, Paint()..color = Colors.white);

        if (overflow > 0) {
          _drawFace(
            canvas,
            person: null,
            overflow: overflow,
            left: _clusterPadding + faces * _clusterFaceStep,
            top: _clusterPadding,
            size: _clusterFaceSize,
          );
        }
        // Right to left, so the leftmost face paints on top like the web stack.
        for (var i = faces - 1; i >= 0; i--) {
          _drawFace(
            canvas,
            person: members[i],
            image: avatarImages[i],
            left: _clusterPadding + i * _clusterFaceStep,
            top: _clusterPadding,
            size: _clusterFaceSize,
          );
        }

        final dot = Offset(width / 2, dotCenterY);
        canvas.drawCircle(
          dot,
          _clusterDotSize / 2,
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(
          dot,
          _clusterDotSize / 2 - 2.5,
          Paint()..color = allStale ? Colors.grey.shade600 : markerAccentColor,
        );
      },
      id: id,
      anchorOffsetY: _clusterHeight - dotCenterY,
    );
  }

  /// The web client's checkpoint name: a dark pill with a pin glyph, shown
  /// from zoom 13. Sized to the text, so the caller caches it per name.
  Future<MarkerImage> checkpointLabel(
    String name, {
    required Color accent,
  }) async {
    final id = 'label-${_hashed('$name|${accent.toARGB32()}')}';
    final cached = _cached(id);
    if (cached != null) return cached;

    final iconPainter = _iconPainter(Icons.place_rounded, 14, accent);
    final textPainter = TextPainter(
      text: TextSpan(
        text: name,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 16 / 12,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const padLeft = 6.0;
    const padRight = 10.0;
    const padY = 3.0;
    const gap = 4.0;
    final width =
        padLeft + iconPainter.width + gap + textPainter.width + padRight;
    final height = textPainter.height + padY * 2;

    final image = await _render(width, height, (canvas) {
      final rect = Rect.fromLTWH(0, 0, width, height);
      final pill = RRect.fromRectAndRadius(rect, Radius.circular(height / 2));
      canvas.drawShadow(Path()..addRRect(pill), Colors.black, 4, false);
      canvas.drawRRect(pill, Paint()..color = const Color(0xEB252B2A));
      iconPainter.paint(
        canvas,
        Offset(padLeft, rect.center.dy - iconPainter.height / 2),
      );
      textPainter.paint(
        canvas,
        Offset(
          padLeft + iconPainter.width + gap,
          rect.center.dy - textPainter.height / 2,
        ),
      );
    }, id: id);
    iconPainter.dispose();
    textPainter.dispose();
    return image;
  }

  /// The soft pulse under a moving person, sized by the caller so it can breathe
  /// without re-rendering anything: the web fades and scales this circle.
  Future<MarkerImage> pulseMarker(Color color) async {
    final id = 'pulse-${color.toARGB32()}';
    final cached = _cached(id);
    if (cached != null) return cached;
    return _render(80, 80, (canvas) {
      canvas.drawCircle(
        const Offset(40, 40),
        40,
        Paint()..color = color.withValues(alpha: 0.22),
      );
    }, id: id);
  }

  /// A rounded-square calendar pin in the event's colour.
  Future<MarkerImage> eventMarker(Color color) async {
    final id = 'event-${color.toARGB32()}';
    final cached = _cached(id);
    if (cached != null) return cached;

    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return _render(44, 44, (canvas) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(4, 4, 36, 36),
        const Radius.circular(12),
      );
      canvas.drawRRect(
        rect.shift(const Offset(0, 2)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawRRect(rect, Paint()..color = color);
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white,
      );
      _drawCalendarGlyph(canvas, const Rect.fromLTWH(13, 13, 18, 18), onColor);
    }, id: id);
  }

  /// A small round endpoint for replay start/finish.
  Future<MarkerImage> endpointMarker(Color color) async {
    final id = 'endpoint-${color.toARGB32()}';
    final cached = _cached(id);
    if (cached != null) return cached;
    return _render(20, 20, (canvas) {
      final center = const Offset(10, 10);
      canvas.drawCircle(center, 10, Paint()..color = Colors.white);
      canvas.drawCircle(
        center,
        7,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
    }, id: id);
  }

  /// The direction cone drawn under a moving marker; rotated per annotation.
  Future<MarkerImage> headingBeam(Color color) async {
    final id = 'beam-${color.toARGB32()}';
    final cached = _cached(id);
    if (cached != null) return cached;
    // PeerMarker.vue's beam: a 56 degree cone reaching 77 px from the centre.
    return _render(154, 154, (canvas) {
      final center = const Offset(77, 77);
      const radius = 77.0;
      const halfAngle = 28.0 * math.pi / 180;
      const up = -math.pi / 2;
      final rect = Rect.fromCircle(center: center, radius: radius);
      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(rect, up - halfAngle, halfAngle * 2, false)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.14)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
      canvas.drawPath(
        path,
        Paint()
          ..shader = ui.Gradient.radial(center, radius, [
            color.withValues(alpha: 0.55),
            color.withValues(alpha: 0.0),
          ]),
      );
    }, id: id);
  }

  ui.Image? _avatarFor(MarkerPerson person) {
    final key = _avatarKey(person);
    if (key == null) return null;
    final loaded = _avatars[key];
    if (loaded != null) return loaded;
    if (_avatarFailed.contains(key)) return null;
    if (_avatarPending.add(key)) {
      // Not awaited: the marker shows the initial immediately and the id
      // changes to the photo variant when this completes.
      unawaited(
        _loadAvatar(person).then((image) {
          _avatarPending.remove(key);
          if (image != null) {
            if (_disposed) {
              image.dispose();
            } else {
              _avatars[key] = image;
            }
          } else {
            _avatarFailed.add(key);
          }
          if (!_disposed) notifyListeners();
        }),
      );
    }
    return null;
  }

  String? _avatarKey(MarkerPerson person) {
    final bytes = person.avatarBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return 'local:${person.id}:${identityHashCode(bytes)}';
    }
    final urls = avatarCandidateUrls(person.id, avatarUrl: person.avatarUrl);
    return urls.isEmpty ? null : urls.join('|');
  }

  Future<ui.Image?> _loadAvatar(MarkerPerson person) async {
    final bytes = person.avatarBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return _decode(ResizeImage.resizeIfNeeded(128, 128, MemoryImage(bytes)));
    }
    // A legacy avatar_url can answer with HTML instead of an image, so every
    // candidate gets its own attempt before falling back to the initial.
    for (final url in avatarCandidateUrls(
      person.id,
      avatarUrl: person.avatarUrl,
    )) {
      final image = await _decode(
        ResizeImage.resizeIfNeeded(128, 128, NetworkImage(url)),
      );
      if (image != null) return image;
    }
    return null;
  }

  Future<ui.Image?> _decode(ImageProvider provider) async {
    final completer = Completer<ui.Image?>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        stream.removeListener(listener);
        return null;
      },
    );
  }

  /// Identity of a cluster bitmap. Selection is not part of it: the caller
  /// scales the annotation instead of baking another bitmap.
  String _liveId(List<MarkerPerson> members, bool allStale) {
    final buffer = StringBuffer('cluster:$allStale');
    for (final member in members) {
      buffer
        ..write('|')
        ..write(_personToken(member))
        ..write(member.isStale ? ':s' : '');
    }
    return _hashed(buffer.toString());
  }

  String _personToken(MarkerPerson person) {
    final avatar = _avatarKey(person);
    final avatarState = avatar == null
        ? 'none'
        : _avatars.containsKey(avatar)
        ? 'ready'
        : _avatarFailed.contains(avatar)
        ? 'failed'
        : 'initial';
    return '${person.id}:${person.name}:$avatarState'
        '${person.isSelf ? ':self' : ''}${person.isStale ? ':stale' : ''}';
  }

  String _hashed(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16);
  }

  Future<MarkerImage> _render(
    double logicalWidth,
    double logicalHeight,
    void Function(Canvas canvas) draw, {
    required String id,
    double anchorOffsetY = 0,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(pixelRatio, pixelRatio);
    draw(canvas);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (logicalWidth * pixelRatio).round(),
      (logicalHeight * pixelRatio).round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    final bytes = data?.buffer.asUint8List() ?? Uint8List(0);
    final marker = MarkerImage(
      id: id,
      width: (logicalWidth * pixelRatio).round(),
      height: (logicalHeight * pixelRatio).round(),
      scale: pixelRatio,
      png: bytes,
      anchorOffsetY: anchorOffsetY,
    );
    _store(marker);
    return marker;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final image in _avatars.values) {
      image.dispose();
    }
    _avatars.clear();
    _icons.clear();
    super.dispose();
  }

  void _drawFace(
    Canvas canvas, {
    required MarkerPerson? person,
    ui.Image? image,
    int overflow = 0,
    required double left,
    required double top,
    required double size,
  }) {
    final rect = Rect.fromLTWH(left, top, size, size);
    final center = rect.center;
    if (person == null) {
      canvas.drawCircle(
        center,
        size / 2,
        Paint()..color = const Color(0xFF2B3134),
      );
      _drawText(
        canvas,
        '+$overflow',
        center,
        const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      );
      return;
    }

    final color = person.isStale ? Colors.grey.shade600 : userColor(person.id);
    final saturated = person.isStale ? Colors.grey.shade500 : color;
    canvas.drawCircle(center, size / 2, Paint()..color = saturated);
    if (image != null) {
      canvas.save();
      canvas.clipPath(
        Path()..addOval(Rect.fromCircle(center: center, radius: size / 2)),
      );
      _drawImageCover(canvas, image, rect, stale: person.isStale);
      canvas.restore();
    } else {
      _drawText(
        canvas,
        userInitial(person.name),
        center,
        TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
        ),
      );
    }
    canvas.drawCircle(
      center,
      size / 2 - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white,
    );
  }

  /// Just the photo (or the initial) in a circle, without the badge styling.
  void _drawRoundAvatar(
    Canvas canvas, {
    required MarkerPerson person,
    ui.Image? image,
    required Offset center,
    required double size,
  }) {
    final radius = size / 2;
    final circle = Rect.fromCircle(center: center, radius: radius);
    canvas.save();
    canvas.clipPath(Path()..addOval(circle));
    if (image != null) {
      _drawImageCover(canvas, image, circle, stale: person.isStale);
    } else {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = person.isStale
              ? Colors.grey.shade600
              : userColor(person.id),
      );
      _drawText(
        canvas,
        userInitial(person.name),
        center,
        TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      );
    }
    canvas.restore();
  }

  TextPainter _iconPainter(IconData icon, double size, Color color) {
    return TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// A dark badge with a Material glyph and 10 px white text, as the web draws
  /// its speed and battery pills. Anchored by its right edge or its centre.
  Rect _badge(
    Canvas canvas, {
    required IconData icon,
    required String text,
    required double top,
    required Color background,
    double? right,
    double? centerX,
  }) {
    final iconPainter = _iconPainter(icon, _badgeIconSize, Colors.white);
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: _badgeFontSize,
          fontWeight: FontWeight.w600,
          height: 12 / 10,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final contentWidth = iconPainter.width + _badgeGap + textPainter.width;
    final width = contentWidth + _badgePadX * 2;
    final left = right != null ? right - width : (centerX ?? 0) - width / 2;
    final rect = Rect.fromLTWH(left, top, width, _badgeHeight);
    final pill = RRect.fromRectAndRadius(rect, const Radius.circular(999));
    canvas.drawShadow(Path()..addRRect(pill), Colors.black, 3, false);
    canvas.drawRRect(pill, Paint()..color = background);
    iconPainter.paint(
      canvas,
      Offset(rect.left + _badgePadX, rect.center.dy - iconPainter.height / 2),
    );
    textPainter.paint(
      canvas,
      Offset(
        rect.left + _badgePadX + iconPainter.width + _badgeGap,
        rect.center.dy - textPainter.height / 2,
      ),
    );
    iconPainter.dispose();
    textPainter.dispose();
    return rect;
  }

  /// The battery glyph for a charge level, as the web client picks it.
  IconData _batteryIcon(int level, bool charging) {
    if (charging) return Icons.battery_charging_full_rounded;
    if (level >= 90) return Icons.battery_full_rounded;
    if (level >= 70) return Icons.battery_5_bar_rounded;
    if (level >= 55) return Icons.battery_4_bar_rounded;
    if (level >= 40) return Icons.battery_3_bar_rounded;
    if (level >= 25) return Icons.battery_2_bar_rounded;
    if (level >= 10) return Icons.battery_1_bar_rounded;
    return Icons.battery_alert_rounded;
  }

  void _drawImageCover(
    Canvas canvas,
    ui.Image image,
    Rect target, {
    bool stale = false,
  }) {
    final src = _coverSource(image, target.size);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    if (stale) {
      paint.colorFilter = const ColorFilter.matrix(_greyscale);
    }
    canvas.drawImageRect(image, src, target, paint);
  }

  static const _greyscale = <double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ];

  Rect _coverSource(ui.Image image, Size target) {
    final imageRatio = image.width / image.height;
    final targetRatio = target.width / target.height;
    if (imageRatio > targetRatio) {
      final width = image.height * targetRatio;
      return Rect.fromLTWH(
        (image.width - width) / 2,
        0,
        width,
        image.height.toDouble(),
      );
    }
    final height = image.width / targetRatio;
    return Rect.fromLTWH(
      0,
      (image.height - height) / 2,
      image.width.toDouble(),
      height,
    );
  }

  void _drawText(Canvas canvas, String text, Offset center, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  void _drawCalendarGlyph(Canvas canvas, Rect rect, Color color) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(rect.left, rect.top + 3, rect.width, rect.height - 3),
      const Radius.circular(2.5),
    );
    canvas.drawRRect(body, stroke);
    canvas.drawLine(
      Offset(rect.left, rect.top + 8),
      Offset(rect.right, rect.top + 8),
      stroke,
    );
    canvas.drawLine(
      Offset(rect.left + 4.5, rect.top),
      Offset(rect.left + 4.5, rect.top + 5),
      stroke,
    );
    canvas.drawLine(
      Offset(rect.right - 4.5, rect.top),
      Offset(rect.right - 4.5, rect.top + 5),
      stroke,
    );
    final dot = Paint()..color = color;
    canvas.drawCircle(Offset(rect.left + 5, rect.top + 13), 1.4, dot);
    canvas.drawCircle(Offset(rect.center.dx, rect.top + 13), 1.4, dot);
    canvas.drawCircle(Offset(rect.right - 5, rect.top + 13), 1.4, dot);
  }

  Path _bubblePath({
    required double width,
    required double bubbleHeight,
    required double tailHeight,
  }) {
    const tailHalfWidth = 8.0;
    final radius = bubbleHeight / 2;
    final centerX = width / 2;
    return Path()
      ..moveTo(radius, 0)
      ..lineTo(width - radius, 0)
      ..arcToPoint(
        Offset(width - radius, bubbleHeight),
        radius: Radius.circular(radius),
      )
      ..lineTo(centerX + tailHalfWidth, bubbleHeight)
      ..quadraticBezierTo(
        centerX + 2,
        bubbleHeight + tailHeight * 0.6,
        centerX,
        bubbleHeight + tailHeight,
      )
      ..quadraticBezierTo(
        centerX - 2,
        bubbleHeight + tailHeight * 0.6,
        centerX - tailHalfWidth,
        bubbleHeight,
      )
      ..lineTo(radius, bubbleHeight)
      ..arcToPoint(Offset(radius, 0), radius: Radius.circular(radius))
      ..close();
  }
}
