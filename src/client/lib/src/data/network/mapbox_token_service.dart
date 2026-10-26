import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Mints short-lived Mapbox tokens (`tk.*`) for the phone app.
///
/// Release builds carry no Mapbox token, so the app asks the tracker for one
/// at runtime: `POST /api/v1/mapbox/token`. Tokens are cached until shortly
/// before they expire, and only the app's own sessions may mint them.
class MapboxTokenService {
  MapboxTokenService({
    required this.baseUrl,
    required this.getAccessToken,
    http.Client? httpClient,
    this.ttlSeconds = 3300,
    this.refreshMarginSeconds = 300,
  }) : _client = httpClient ?? http.Client();

  final String baseUrl;

  /// Callback so a refreshed access token is always used (the service can
  /// outlive any single token's validity).
  final String? Function() getAccessToken;

  /// Requested lifetime, in seconds. Capped at one hour by Mapbox; the server
  /// applies the same default.
  final int ttlSeconds;

  /// Renew this long before expiry, so the map never holds a dead token.
  final int refreshMarginSeconds;

  final http.Client _client;
  String? _token;
  DateTime? _refreshAt;
  bool _fetching = false;
  Completer<String?>? _inFlight;

  /// Current short-lived token, minting or refreshing it as needed. Returns
  /// `null` when the server cannot issue a token (not configured or unreachable).
  Future<String?> get token async {
    final now = DateTime.now();
    if (_token != null && _refreshAt != null && now.isBefore(_refreshAt!)) {
      return _token;
    }
    if (_fetching) {
      return _inFlight?.future ?? _token;
    }
    return _mint();
  }

  Future<String?> _mint() async {
    _fetching = true;
    final completer = Completer<String?>();
    _inFlight = completer;
    try {
      final now = DateTime.now();
      final accessToken = getAccessToken();
      if (accessToken == null || accessToken.isEmpty) {
        completer.complete(null);
        return null;
      }
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/v1/mapbox/token'),
            // No body, so no content-type: Fastify rejects a body-less
            // request that claims to send JSON.
            headers: {'authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final token = body['token'] as String?;
        if (token == null || token.isEmpty) {
          completer.complete(null);
          return null;
        }
        _token = token;
        final expiresAtRaw = body['expires_at'] as String?;
        final parsed = expiresAtRaw != null
            ? DateTime.tryParse(expiresAtRaw)
            : null;
        final expiresAt =
            parsed ?? DateTime.now().add(Duration(seconds: ttlSeconds));
        // Never refresh earlier than one second from now; cap the margin at
        // the token's remaining lifetime.
        final margin = refreshMarginSeconds.clamp(0, ttlSeconds);
        final refreshAt = expiresAt.subtract(Duration(seconds: margin));
        _refreshAt = refreshAt.isAfter(now)
            ? refreshAt
            : now.add(const Duration(seconds: 1));
        completer.complete(_token);
        return _token;
      }
      completer.complete(null);
      return null;
    } catch (_) {
      completer.complete(null);
      return null;
    } finally {
      _fetching = false;
      _inFlight = null;
    }
  }

  /// Discards the cached token so the next [token] access mints a fresh one.
  /// Call this when a map style fails, which suggests the token expired.
  void invalidate() {
    _token = null;
    _refreshAt = null;
  }

  void dispose() {
    _inFlight?.complete(null);
    _inFlight = null;
    _client.close();
  }

  @override
  String toString() => 'MapboxTokenService';
}
