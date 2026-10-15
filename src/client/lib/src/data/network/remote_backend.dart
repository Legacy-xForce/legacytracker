import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../data/models/location_model.dart';
import '../../data/models/map_viewer.dart';
import '../../data/models/user_model.dart';
import 'backend.dart';

class RemoteBackend implements Backend {
  RemoteBackend({
    required this.baseUrl,
    required this.getAccessToken,
    required this.selfId,
  });

  final String baseUrl;
  // A callback rather than a captured string — the access token can be
  // refreshed by [AuthProvider] at any time (e.g. on app resume), and this
  // backend instance lives far longer than any single token's validity.
  final String Function() getAccessToken;
  final String selfId;
  final http.Client _httpClient = http.Client();
  final StreamController<List<UserProfile>> _peerController =
      StreamController<List<UserProfile>>.broadcast();
  final StreamController<List<MapViewer>> _viewerController =
      StreamController<List<MapViewer>>.broadcast();
  final Map<String, UserProfile> _peerCache = {};
  WebSocketChannel? _channel;
  String? _ticket;
  bool _initialized = false;
  bool _disposed = false;
  // While the app is in the background nobody is looking at the map: keeping
  // the socket (and its 15 s keep-alive pings) open would only cost battery.
  bool _suspended = false;
  Timer? _reconnectTimer;
  // Map tab is the default landing tab, so a freshly-opened session starts
  // "active" — this mirrors the server's ConnectionManager default and keeps
  // the two in sync without needing an extra message on the very first
  // connect.
  bool _mapActive = true;

  @override
  Stream<List<UserProfile>> get peerStream => _peerController.stream;

  @override
  Stream<List<MapViewer>> get viewerStream => _viewerController.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    await _connectFreshWebSocket();
    _initialized = true;
  }

  @override
  Future<void> registerFcmToken(String token) async {
    final uri = _apiUri('/api/v1/fcm-token');
    try {
      await _httpClient.post(
        uri,
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer ${getAccessToken()}',
        },
        body: jsonEncode({'token': token}),
      );
    } catch (_) {
      // Non-critical — FCM pacing updates simply won't arrive if this fails.
    }
  }

  @override
  void setMapActive(bool active) {
    _mapActive = active;
    _sendMapActive();
  }

  void _sendMapActive() {
    if (_channel == null) {
      return;
    }
    try {
      _channel!.sink.add(jsonEncode({'type': 'map_active', 'active': _mapActive}));
    } catch (_) {
      // Best-effort; the current state is resent on the next successful
      // connect, so a dropped send here just means a brief delay.
    }
  }

  @override
  void suspend() {
    if (_suspended) return;
    _suspended = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final channel = _channel;
    _channel = null;
    channel?.sink.close();
    // Not kept up to date from here on; the server sends a fresh list when we
    // reconnect.
    _viewerController.add(const []);
  }

  @override
  void resume() {
    if (!_suspended) return;
    _suspended = false;
    if (!_initialized || _disposed) return;
    // A fresh connection also brings a fresh snapshot of everyone.
    _connectFreshWebSocket().catchError((Object error) {
      dev.log('[ws] resume failed: $error', name: 'RemoteBackend');
      _scheduleReconnect();
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _channel?.sink.close();
    _peerController.close();
    _viewerController.close();
    _httpClient.close();
  }

  Future<String> _requestTicket() async {
    final uri = _apiUri('/api/v1/streams/ticket');
    final response = await _httpClient.post(
      uri,
      headers: {'authorization': 'Bearer ${getAccessToken()}'},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Unable to obtain streaming ticket (status ${response.statusCode})',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final ticket = body['ticket'] as String?;
    if (ticket == null || ticket.isEmpty) {
      throw Exception('Invalid ticket response');
    }

    return ticket;
  }

  void _connectWebSocket() {
    if (_ticket == null) {
      return;
    }

    _channel?.sink.close();
    final uri = _webSocketUri(_ticket!);
    // A plain WebSocketChannel.connect never notices a connection that goes
    // silently dead (e.g. airplane mode, which often doesn't produce an
    // immediate TCP RST), so peer updates would just stop arriving.
    // IOWebSocketChannel's pingInterval makes the underlying dart:io
    // WebSocket send periodic pings and auto-close the connection if a pong
    // doesn't come back in time, which drives onDone/_scheduleReconnect.
    final channel = IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 15),
    );
    _channel = channel;
    dev.log('[ws] connecting to $uri', name: 'RemoteBackend');
    // The server only learns the map-active state via this message, so a
    // fresh (or reconnected) socket needs to (re)announce it — the server
    // has no memory of a dropped connection's last-known state.
    _sendMapActive();
    channel.stream.listen(
      _handleWebSocketMessage,
      onError: (error) {
        dev.log('[ws] error: $error', name: 'RemoteBackend');
        // Ignore a superseded socket (e.g. one closed by suspend()).
        if (identical(_channel, channel)) _scheduleReconnect();
      },
      onDone: () {
        if (!identical(_channel, channel)) return;
        dev.log(
          '[ws] connection closed, scheduling reconnect',
          name: 'RemoteBackend',
        );
        _scheduleReconnect();
      },
    );
  }

  Future<void> _connectFreshWebSocket() async {
    if (_disposed || _suspended) {
      return;
    }

    _ticket = await _requestTicket();
    if (_disposed || _suspended) {
      return;
    }
    _connectWebSocket();
  }

  void _handleWebSocketMessage(dynamic message) {
    if (message is! String) {
      return;
    }

    dev.log('[ws] received: $message', name: 'RemoteBackend');
    final decoded = jsonDecode(message);
    if (decoded is Map<String, dynamic>) {
      if (decoded['type'] == 'snapshot' && decoded['users'] is List) {
        _handleSnapshot(List<dynamic>.from(decoded['users'] as List));
        return;
      }
      final viewers = MapViewer.listFromMessage(decoded);
      if (viewers != null) {
        _viewerController.add(viewers);
        return;
      }
      _handlePeerUpdate(decoded);
      return;
    }

    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          _handlePeerUpdate(item);
        }
      }
    }
  }

  void _handleSnapshot(List<dynamic> users) {
    for (final item in users) {
      if (item is Map<String, dynamic>) {
        _handlePeerUpdate(item);
      }
    }
  }

  void _handlePeerUpdate(Map<String, dynamic> payload) {
    final remoteUserId = payload['user_id'] as String?;
    if (remoteUserId == null || remoteUserId == selfId) {
      return;
    }

    final existingProfile = _peerCache[remoteUserId];
    final incomingName = payload['username'] as String?;
    final profile =
        existingProfile ??
        UserProfile(
          id: remoteUserId,
          name: incomingName ?? remoteUserId,
          avatarUrl: '',
        );
    if (incomingName != null && incomingName != remoteUserId) {
      profile.name = incomingName;
    }

    // Roster-only snapshot entries (a user who has never broadcast a
    // location) carry no latitude/longitude — register the peer without
    // touching lastLocation rather than dropping them entirely.
    final latitude = _parseDouble(payload['latitude']);
    final longitude = _parseDouble(payload['longitude']);
    if (latitude != null && longitude != null) {
      final speed = _parseDouble(payload['speed']) ?? 0.0;
      final heading = _parseDouble(payload['heading']);
      final recordedAt =
          DateTime.tryParse(payload['recorded_at'] as String? ?? '') ??
          DateTime.now();

      final point = LocationPoint(
        latitude: latitude,
        longitude: longitude,
        speed: speed,
        heading: heading,
        timestamp: recordedAt,
      );
      profile.lastLocation = point;
      profile.history = [point, ...profile.history].take(20).toList();
    }
    // Sent with every update, coordinates or not; null while travelling.
    if (payload.containsKey('here_since')) {
      final hereSinceRaw = payload['here_since'] as String?;
      profile.hereSince = hereSinceRaw == null
          ? null
          : DateTime.tryParse(hereSinceRaw);
    }
    final lastSeenRaw = payload['last_seen_at'] as String?;
    if (lastSeenRaw != null) {
      profile.lastSeenAt =
          DateTime.tryParse(lastSeenRaw) ?? profile.lastSeenAt;
    }
    profile.locationTrackingPaused =
        payload['location_tracking_paused'] as bool? ??
        profile.locationTrackingPaused;
    profile.missingPermissions =
        payload['missing_permissions'] as bool? ?? profile.missingPermissions;
    profile.batterySavingEnabled =
        payload['battery_saving_enabled'] as bool? ??
        profile.batterySavingEnabled;
    profile.batteryLevel =
        (payload['battery_level'] as num?)?.toInt() ?? profile.batteryLevel;
    profile.isCharging = payload['is_charging'] as bool? ?? profile.isCharging;
    // Present on roster entries and on changes to who is sharing with us.
    if (payload.containsKey('sharing')) {
      profile.sharesWithMe = payload['sharing'] as bool? ?? true;
      if (!profile.sharesWithMe) {
        profile.lastLocation = null;
        profile.history = [];
        profile.hereSince = null;
        profile.lastSeenAt = null;
        profile.batteryLevel = null;
        profile.isCharging = null;
      }
    }
    _peerCache[remoteUserId] = profile;
    _peerController.add(
      List<UserProfile>.unmodifiable(_peerCache.values.toList()),
    );
  }

  double? _parseDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  Uri _apiUri(String path) {
    final target = Uri.parse(baseUrl);
    return target.replace(path: path, queryParameters: null);
  }

  Uri _webSocketUri(String ticket) {
    final target = Uri.parse(baseUrl);
    final scheme = target.scheme == 'https' ? 'wss' : 'ws';

    return Uri(
      scheme: scheme,
      host: target.host,
      port: target.hasPort ? target.port : (scheme == 'wss' ? 443 : 80),
      path: '/api/v1/stream',
      queryParameters: {'ticket': ticket},
    );
  }

  void _scheduleReconnect() {
    if (_disposed || _suspended) {
      return;
    }

    _channel = null;
    _reconnectTimer?.cancel();
    dev.log('[ws] reconnecting in 3s', name: 'RemoteBackend');
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      _connectFreshWebSocket().catchError((error) {
        dev.log('[ws] reconnect failed: $error', name: 'RemoteBackend');
        _scheduleReconnect();
      });
    });
  }
}
