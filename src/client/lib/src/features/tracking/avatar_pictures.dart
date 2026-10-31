import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// What this session knows about one person's profile picture.
@immutable
class AvatarPicture {
  const AvatarPicture.ready(Uint8List this.bytes) : retryable = false;

  /// Nobody has a picture at any of the candidate URLs (Legacy Auth answers
  /// 404 for an account without one). Asking again this session is pointless.
  const AvatarPicture.missing() : bytes = null, retryable = false;

  /// The fetch failed for a reason that may clear up — no network, a timeout,
  /// a 429 or a 5xx — so the caller should ask again later.
  const AvatarPicture.unavailable() : bytes = null, retryable = true;

  final Uint8List? bytes;

  /// Whether another attempt could still find a picture.
  final bool retryable;
}

/// Fetches profile pictures and keeps them for the session.
///
/// `Image.network` used to do this per widget, which made the people list
/// flaky: opening someone's details and going back remounted the image, so it
/// fetched the picture again; Flutter's image cache drops a failed key, so
/// every remount retried a load that had already failed; and a stale legacy
/// `avatar_url` that hung (no timeout on `Image.network`) kept the Legacy Auth
/// picture from ever being tried. The slower the network, the more of those
/// requests piled up, which is why switching people quickly made each photo
/// take longer.
///
/// This walks a person's candidate URLs once, with a timeout per candidate,
/// keeps a successful picture (or a definitive "no picture") for the session,
/// and retries a temporary failure with a backoff instead of waiting for the
/// user to reopen the list.
class AvatarPictures {
  AvatarPictures({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 6),
    this.retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 15),
    ],
  }) : _client = client ?? http.Client();

  /// The app's cache. Tests build their own with a fake client.
  static final AvatarPictures instance = AvatarPictures();

  final http.Client _client;

  /// How long a single candidate URL may take before the next one is tried.
  final Duration requestTimeout;

  /// Backoff between attempts when every candidate failed temporarily.
  final List<Duration> retryDelays;

  final Map<String, AvatarPicture> _pictures = {};
  final Map<String, Future<AvatarPicture>> _pending = {};

  /// The answer if this session already has one, without starting a request.
  AvatarPicture? peek(String key) => _pictures[key];

  /// The picture for [key], loading it from [urls] (in order) if needed.
  ///
  /// Concurrent callers share one request, and a ready or missing answer is
  /// served from memory, so rebuilding or remounting an avatar costs nothing.
  Future<AvatarPicture> load(String key, List<String> urls) {
    final known = _pictures[key];
    if (known != null) return Future.value(known);
    final pending = _pending[key];
    if (pending != null) return pending;

    final future = _load(urls).then((picture) {
      // A temporary failure is not remembered: the next mount may try again.
      if (!picture.retryable) _pictures[key] = picture;
      return picture;
    });
    _pending[key] = future;
    return future.whenComplete(() => _pending.remove(key));
  }

  Future<AvatarPicture> _load(List<String> urls) async {
    for (var attempt = 0; ; attempt++) {
      final result = await _attempt(urls);
      if (result.bytes != null) return result;
      if (!result.retryable || attempt >= retryDelays.length) return result;
      await Future<void>.delayed(retryDelays[attempt]);
    }
  }

  /// Tries every candidate once. A candidate that fails definitively (a 404,
  /// or a 200 that is not a picture) moves on to the next; only a temporary
  /// failure makes the whole chain worth retrying.
  Future<AvatarPicture> _attempt(List<String> urls) async {
    var retryable = false;
    for (final url in urls) {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) continue;
      try {
        final response = await _client.get(uri).timeout(requestTimeout);
        if (response.statusCode == 200) {
          final bytes = response.bodyBytes;
          if (bytes.isNotEmpty && await _isPicture(bytes)) {
            return AvatarPicture.ready(bytes);
          }
          // A legacy path can answer 200 with the sign-in page; that is a
          // broken candidate, not a broken connection.
        } else if (_mayClearUp(response.statusCode)) {
          retryable = true;
        }
      } on TimeoutException {
        retryable = true;
      } catch (_) {
        retryable = true;
      }
    }
    return retryable
        ? const AvatarPicture.unavailable()
        : const AvatarPicture.missing();
  }

  static bool _mayClearUp(int status) =>
      status == 408 || status == 429 || status >= 500;

  /// Decodes a tiny version of the payload to tell a picture from an HTML
  /// error page. The real decode happens once, when it is displayed.
  static Future<bool> _isPicture(Uint8List bytes) async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 32);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      return true;
    } catch (_) {
      return false;
    } finally {
      codec?.dispose();
    }
  }

  /// Forget everything, e.g. after signing out.
  void clear() {
    _pictures.clear();
    _pending.clear();
  }
}
