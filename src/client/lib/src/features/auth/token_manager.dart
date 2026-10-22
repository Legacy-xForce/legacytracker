import 'dart:async';

import '../../data/network/auth_service.dart';
import '../../data/network/oidc_service.dart';
import '../../data/storage/token_storage.dart';

/// An access token for one app.
class AccessGrant {
  AccessGrant(this.token, this.expiresAt);

  final String token;
  final DateTime expiresAt;

  /// Renewed a minute early so no request goes out with a token about to lapse.
  bool get isFresh =>
      expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 1)));
}

/// The session's tokens: one OP grant (its refresh token in secure storage)
/// that yields a tracker token and, for accounts with the calendar, a calendar
/// token. Or, until it fails, a session from the old password login.
///
/// The OP rotates the refresh token on every use and revokes the whole grant
/// when an old one is presented again, so every refresh runs through one
/// queue, and the new refresh token is stored before its access token is used.
class TokenManager {
  TokenManager({
    required this.oidc,
    required this.legacyAuth,
    required this.storage,
  });

  final OidcService oidc;
  final AuthService legacyAuth;
  final TokenStorage storage;

  StoredGrant? _grant;
  StoredAuthData? _legacy;
  AccessGrant? _tracker;
  AccessGrant? _calendar;
  bool _calendarRefused = false;
  Future<void> _queue = Future.value();

  bool get hasSession => _grant != null || _legacy != null;
  bool get isLegacy => _legacy != null;

  String? get accessToken => _tracker?.token;
  bool get trackerTokenFresh => _tracker?.isFresh ?? false;
  DateTime? get trackerExpiresAt => _tracker?.expiresAt;
  DateTime? get calendarExpiresAt => _calendar?.expiresAt;
  String? get idToken => _grant?.idToken;

  String? get userId =>
      _grant?.userId ?? _claim(_tracker?.token, 'sub');
  String? get username => _grant?.username ?? _legacy?.username;

  /// Whether the account has the calendar, by the tracker token's `scopes`
  /// claim, which the OP fills in fresh at every issuance. Read *before*
  /// asking for a calendar token: a refused refresh spends the refresh token.
  bool get mayUseCalendar {
    final scopes = jwtClaims(_tracker?.token)?['scopes'];
    final entitled = scopes is Map && scopes['calendar'] == true;
    if (isLegacy) return entitled;
    return entitled && (_grant?.calendar ?? false) && !_calendarRefused;
  }

  /// A token Legacy Calendar accepts, once one was issued. Old password-login
  /// tokens are addressed to both apps.
  String? get calendarAccessToken {
    if (isLegacy) return mayUseCalendar ? _tracker?.token : null;
    return mayUseCalendar ? _calendar?.token : null;
  }

  /// Reads the stored session, if any. Tokens come with the first refresh.
  Future<void> load() async {
    _grant = await storage.loadGrant();
    if (_grant != null) return;
    _legacy = await storage.loadLegacy();
    // Its access token was stored too: usable until it expires.
    if (_legacy case final legacy?) {
      _tracker = AccessGrant(legacy.tokens.accessToken, legacy.tokens.expiresAt);
    }
  }

  /// Adopts a completed sign-in. Replaces any legacy session.
  Future<void> adoptSignIn(OidcTokens tokens, {required bool calendar}) {
    return _serial(() async {
      final userId = _claim(tokens.accessToken, 'sub');
      if (userId == null) {
        throw AuthException('Unexpected answer from the sign-in server.');
      }
      final grant = StoredGrant(
        refreshToken: tokens.refreshToken,
        idToken: tokens.idToken,
        calendar: calendar,
        userId: userId,
        username:
            _claim(tokens.accessToken, 'username') ??
            _claim(tokens.accessToken, 'preferred_username') ??
            userId,
      );
      await storage.clearLegacy();
      await storage.saveGrant(grant);
      _grant = grant;
      _legacy = null;
      _tracker = AccessGrant(tokens.accessToken, tokens.expiresAt);
      _calendar = null;
      _calendarRefused = false;
    });
  }

  /// Renews the tracker token unless it is still fresh (or [force]). Throws
  /// [AuthRejectedException] when the session is over, [AuthException] or
  /// others when the server can't be reached (keep the session then).
  Future<void> refreshTracker({bool force = false}) {
    return _serial(() async {
      if (!force && trackerTokenFresh) return;
      if (_grant case final grant?) {
        final tokens = await oidc.refresh(grant.refreshToken, trackerResource);
        await _store(grant.withRefreshToken(tokens.refreshToken));
        _tracker = AccessGrant(tokens.accessToken, tokens.expiresAt);
      } else if (_legacy case final legacy?) {
        await _refreshLegacy(legacy);
      } else {
        throw AuthRejectedException('Signed out');
      }
    });
  }

  /// Gets a calendar token when the account has the calendar and the current
  /// one is missing or stale. A refusal hides the calendar for this session;
  /// network failures throw.
  Future<void> refreshCalendar() {
    return _serial(() async {
      final grant = _grant;
      if (grant == null || !mayUseCalendar) return;
      if (_calendar?.isFresh ?? false) return;
      try {
        final tokens = await oidc.refresh(grant.refreshToken, calendarResource);
        await _store(grant.withRefreshToken(tokens.refreshToken));
        _calendar = AccessGrant(tokens.accessToken, tokens.expiresAt);
      } on AuthRejectedException {
        _calendar = null;
        _calendarRefused = true;
      }
    });
  }

  Future<void> clear() async {
    // Waits for a refresh in flight, so it can't store a token after this.
    await _serial(() async {
      _grant = null;
      _legacy = null;
      _tracker = null;
      _calendar = null;
      _calendarRefused = false;
      await storage.clear();
    });
  }

  Future<void> _store(StoredGrant grant) async {
    await storage.saveGrant(grant);
    _grant = grant;
  }

  Future<void> _refreshLegacy(StoredAuthData legacy) async {
    if (legacy.tokens.refreshExpiresAt.isBefore(DateTime.now())) {
      throw AuthRejectedException('Refresh token expired');
    }
    final tokens = await legacyAuth.refresh(legacy.tokens.refreshToken);
    final scopes = jwtClaims(tokens.accessToken)?['scopes'];
    if (!(scopes is Map && scopes['tracker'] == true)) {
      throw AuthRejectedException(noTrackerAccessMessage);
    }
    await storage.saveLegacy(legacy.username, tokens);
    _legacy = StoredAuthData(username: legacy.username, tokens: tokens);
    _tracker = AccessGrant(tokens.accessToken, tokens.expiresAt);
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static String? _claim(String? jwt, String claim) {
    final value = jwtClaims(jwt)?[claim];
    return value is String && value.isNotEmpty ? value : null;
  }
}
