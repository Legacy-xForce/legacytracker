import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../../core/palette.dart';

import '../avatar_pictures.dart';

/// Saturated enough to read on light map tiles and the dark UI alike. The
/// initial is white or near-black, whichever contrasts more ([initialColorFor]).
const avatarPalette = AppPalette.avatars;

const _darkInitial = AppPalette.onAvatarDark;

double _contrast(Color a, Color b) {
  final hi = a.computeLuminance();
  final lo = b.computeLuminance();
  return (hi > lo ? hi + 0.05 : lo + 0.05) / (hi > lo ? lo + 0.05 : hi + 0.05);
}

/// The initial's color on an avatar background: white or near-black,
/// whichever reads better (at least 4.5:1 for every palette color).
Color initialColorFor(Color background) =>
    _contrast(AppPalette.white, background) >= _contrast(_darkInitial, background)
        ? AppPalette.white
        : _darkInitial;

/// A stable color per user, so the same person reads the same on their
/// marker, inside a group bubble and in the people list.
Color userColor(String userId) {
  // FNV-1a: cheap, and stable across runs unlike String.hashCode.
  var hash = 0x811c9dc5;
  for (final unit in userId.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return avatarPalette[hash % avatarPalette.length];
}

String userInitial(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
}

// Luma-weighted desaturation. A matrix, not BlendMode.saturation, which paints a
// grey block over the surrounding scrolling list on Impeller.
const _greyscale = <double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
];

final _accountId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Legacy Auth keeps profile pictures by account id, which is also the
/// tracker's user id. Ids that aren't accounts can't have one.
String? profilePictureUrl(String userId) => _accountId.hasMatch(userId)
    ? 'https://auth.legacy-group.tech/auth/profile-picture/$userId'
    : null;

/// Picture URLs to try for a person, in order.
///
/// Legacy Auth is the source of truth now, so its picture comes first. The
/// tracker still carries an older `avatar_url` for accounts that set one
/// before Legacy Auth took over, but those paths can be dead or slow — trying
/// them first is what left some people with only their initial, because
/// `Image.network` had no timeout to fall through on. The stored URL is kept
/// as a fallback for accounts that never set a picture in Legacy Auth.
List<String> avatarCandidateUrls(String userId, {String avatarUrl = ''}) {
  final auth = profilePictureUrl(userId);
  return <String>[
    ?auth,
    if (avatarUrl.isNotEmpty && avatarUrl != auth) avatarUrl,
  ];
}

/// A person's photo, once [AvatarPictures] has it.
///
/// The picture is cached for the session, so rebuilding or remounting this
/// widget (opening the details and going back, switching people) does not
/// fetch it again. A temporary failure retries on its own instead of waiting
/// for the list to be reopened.
class _AvatarPhoto extends StatefulWidget {
  const _AvatarPhoto({
    required this.userId,
    required this.avatarUrl,
    required this.pictures,
  });

  final String userId;
  final String avatarUrl;
  final AvatarPictures pictures;

  @override
  State<_AvatarPhoto> createState() => _AvatarPhotoState();
}

class _AvatarPhotoState extends State<_AvatarPhoto> {
  /// Long enough not to hammer a phone that is offline, short enough that a
  /// photo that failed on a bad connection still appears without a tap.
  static const _retryDelay = Duration(seconds: 30);

  /// Stop after a few tries. A legacy URL blocked by the platform (cleartext
  /// HTTP in a release build) would otherwise be retried for as long as the
  /// list stays open; reopening it starts over.
  static const _maxRetries = 5;

  AvatarPicture? _picture;
  Timer? _retry;
  int _generation = 0;
  int _retries = 0;

  List<String> get _urls =>
      avatarCandidateUrls(widget.userId, avatarUrl: widget.avatarUrl);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _AvatarPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.userId != oldWidget.userId ||
        widget.avatarUrl != oldWidget.avatarUrl ||
        widget.pictures != oldWidget.pictures) {
      _retry?.cancel();
      _picture = null;
      _retries = 0;
      _load();
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final urls = _urls;
    if (urls.isEmpty) return;

    final picture = await widget.pictures.load(urls.join('|'), urls);
    if (!mounted || generation != _generation) return;
    setState(() => _picture = picture);
    if (!picture.retryable) {
      _retries = 0;
    } else if (_retries < _maxRetries) {
      _retries++;
      _retry?.cancel();
      _retry = Timer(_retryDelay, _load);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _picture?.bytes;
    if (bytes == null) return const SizedBox.shrink();
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      // Avatars are a few dozen pixels. A legacy URL can point at a huge
      // photo, and decoding it at full size for every face made a quick walk
      // through the list feel slow.
      cacheWidth: 256,
      gaplessPlayback: true,
    );
  }
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
    this.pictures,
  });

  final String userId;
  final String name;
  final String avatarUrl;

  /// A local photo (our own picked avatar) takes precedence over [avatarUrl].
  final Uint8List? imageBytes;

  /// Where remote photos are cached. Defaults to the app's session cache;
  /// tests pass their own with a fake client.
  final AvatarPictures? pictures;
  final double size;
  final Color? ringColor;
  final double ringWidth;

  /// Greyed out for users we haven't heard from in a while.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final color = dimmed ? AppPalette.staleDark : userColor(userId);

    // The initial always sits underneath, so it shows while the picture loads
    // and stays when there is none (Legacy Auth answers 404).
    final photo = imageBytes != null
        ? Image.memory(imageBytes!, fit: BoxFit.cover)
        : _AvatarPhoto(
            userId: userId,
            avatarUrl: avatarUrl,
            pictures: pictures ?? AvatarPictures.instance,
          );

    Widget avatar = Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      // Over the photo, so the ring stays visible and separates overlapping faces.
      foregroundDecoration: ringWidth > 0 && ringColor != null
          ? BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: ringColor!, width: ringWidth),
            )
          : null,
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          Center(
            child: Text(
              userInitial(name),
              style: TextStyle(
                color: initialColorFor(color),
                fontSize: size * 0.42,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
          photo,
        ],
      ),
    );

    if (dimmed) {
      avatar = ColorFiltered(
        colorFilter: const ColorFilter.matrix(_greyscale),
        child: avatar,
      );
    }
    return avatar;
  }
}
