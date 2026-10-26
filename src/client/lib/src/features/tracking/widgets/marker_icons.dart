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

/// One person drawn inside a live marker bubble.
class MarkerPerson {
  const MarkerPerson({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    this.avatarBytes,
    this.isStale = false,
    this.isSelected = false,
  });

  final String id;
  final String name;
  final String avatarUrl;
  final Uint8List? avatarBytes;
  final bool isStale;
  final bool isSelected;
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

  /// A live-tracking bubble: one face per person, a short tail and a dot on
  /// the shared location. Mirrors the old Life360-style marker.
  Future<MarkerImage> liveMarker(List<MarkerPerson> members) async {
    final allStale = members.every((m) => m.isStale);
    final id = _liveId(members, allStale);
    final cached = _cached(id);
    if (cached != null) return cached;

    const faceSize = 42.0;
    const padding = 3.0;
    const faceStep = 30.0;
    const tailHeight = 13.0;
    const dotSize = 14.0;
    const maxFaces = 3;

    final faces = members.length > maxFaces ? maxFaces : members.length;
    final overflow = members.length - faces;
    final slots = members.length > maxFaces ? maxFaces + 1 : members.length;
    final bubbleHeight = faceSize + padding * 2;
    final width = padding * 2 + faceSize + (slots - 1) * faceStep;
    final height = bubbleHeight + tailHeight + dotSize / 2;
    final dotCenterY = bubbleHeight + tailHeight;

    final avatarImages = <int, ui.Image?>{
      for (var i = 0; i < faces; i++) i: _avatarFor(members[i]),
    };

    return _render(
      width,
      height,
      (canvas) {
        final path = _bubblePath(
          width: width,
          bubbleHeight: bubbleHeight,
          tailHeight: tailHeight,
        );
        canvas.drawShadow(path, Colors.black, 4, false);
        canvas.drawPath(path, Paint()..color = Colors.white);

        if (overflow > 0) {
          _drawFace(
            canvas,
            person: null,
            overflow: overflow,
            left: padding + faces * faceStep,
            top: padding,
            size: faceSize,
          );
        }
        // Right to left, so the leftmost face paints on top like the old stack.
        for (var i = faces - 1; i >= 0; i--) {
          _drawFace(
            canvas,
            person: members[i],
            image: avatarImages[i],
            left: padding + i * faceStep,
            top: padding,
            size: faceSize,
          );
        }

        final dot = Offset(width / 2, dotCenterY);
        canvas.drawCircle(dot, dotSize / 2, Paint()..color = Colors.white);
        canvas.drawCircle(
          dot,
          dotSize / 2 - 2,
          Paint()..color = allStale ? Colors.grey.shade600 : markerAccentColor,
        );
      },
      id: id,
      anchorOffsetY: height - dotCenterY,
    );
  }

  /// The compact marker used over a replay route: avatar, halo, heading beam
  /// (a separate annotation) and, while moving, a speed badge.
  Future<MarkerImage> replayMarker({
    required MarkerPerson person,
    required double speedKmh,
    required bool isMoving,
  }) async {
    final speedBucket = isMoving ? (speedKmh / 5).round() * 5 : -1;
    final id = 'replay-${_personToken(person)}-$speedBucket';
    final cached = _cached(id);
    if (cached != null) return cached;

    const size = 84.0;
    const height = 96.0;
    const avatarSize = 42.0;
    const center = Offset(size / 2, height / 2);
    final avatar = _avatarFor(person);

    return _render(size, height, (canvas) {
      canvas.drawCircle(
        center,
        34,
        Paint()..color = markerAccentColor.withValues(alpha: 0.16),
      );
      canvas.drawCircle(
        center,
        avatarSize / 2 + 3,
        Paint()..color = Colors.white,
      );
      _drawFace(
        canvas,
        person: person,
        image: avatar,
        left: center.dx - avatarSize / 2,
        top: center.dy - avatarSize / 2,
        size: avatarSize,
      );
      if (isMoving) {
        _drawPill(
          canvas,
          center: Offset(size / 2, height - 12),
          text: '${speedKmh.round()} km/h',
          background: Colors.grey.shade900,
          color: Colors.white,
        );
      }
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
    return _render(120, 120, (canvas) {
      final center = const Offset(60, 60);
      const radius = 56.0;
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
    final url = person.avatarUrl.isNotEmpty
        ? person.avatarUrl
        : profilePictureUrl(person.id);
    return url;
  }

  Future<ui.Image?> _loadAvatar(MarkerPerson person) async {
    final bytes = person.avatarBytes;
    ImageProvider provider;
    if (bytes != null && bytes.isNotEmpty) {
      provider = ResizeImage.resizeIfNeeded(128, 128, MemoryImage(bytes));
    } else {
      final url = person.avatarUrl.isNotEmpty
          ? person.avatarUrl
          : profilePictureUrl(person.id);
      if (url == null) return null;
      provider = ResizeImage.resizeIfNeeded(128, 128, NetworkImage(url));
    }
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

  String _liveId(List<MarkerPerson> members, bool allStale) {
    final buffer = StringBuffer('live:$allStale');
    for (final member in members) {
      buffer
        ..write('|')
        ..write(_personToken(member))
        ..write(member.isStale ? ':s' : '')
        ..write(member.isSelected ? ':x' : '');
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
    return '${person.id}:${person.name}:$avatarState';
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
        ..strokeWidth = person.isSelected ? 3 : 1.5
        ..color = person.isSelected ? markerAccentColor : Colors.white,
    );
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

  void _drawPill(
    Canvas canvas, {
    required Offset center,
    required String text,
    required Color background,
    required Color color,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width + 16;
    final height = painter.height + 8;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: width, height: height),
      const Radius.circular(999),
    );
    canvas.drawRRect(
      rect.shift(const Offset(0, 2)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRRect(rect, Paint()..color = background);
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
