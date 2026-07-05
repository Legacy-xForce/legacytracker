import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../data/models/location_model.dart';
import '../../data/models/user_model.dart';
import 'backend.dart';
import '../../features/location/location_outbox.dart';
import '../../features/location/location_payload.dart';

class RemoteBackend implements Backend {
  RemoteBackend({
    required this.baseUrl,
    required this.accessToken,
    required this.selfId,
  });

  final String baseUrl;
  final String accessToken;
  final String selfId;
  final http.Client _httpClient = http.Client();
  final StreamController<List<UserProfile>> _peerController =
      StreamController<List<UserProfile>>.broadcast();
  final Map<String, UserProfile> _peerCache = {};
  final LocationOutbox _outbox = LocationOutbox();
  WebSocketChannel? _channel;
  String? _ticket;
  bool _initialized = false;
  bool _disposed = false;
  Timer? _reconnectTimer;
  Timer? _outboxFlushTimer;
  bool _flushingOutbox = false;

  @override
  Stream<List<UserProfile>> get peerStream => _peerController.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    await _connectFreshWebSocket();
    _outboxFlushTimer?.cancel();
    _outboxFlushTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _flushPendingLocationUploads(),
    );
    unawaited(_flushPendingLocationUploads());
    _initialized = true;
  }

  @override
  void sendLocationRealtime(
    LocationPoint point, {
    int? batteryLevel,
    bool? isCharging,
  }) {
    if (_channel == null) {
      unawaited(
        _outbox.enqueue(
          buildLocationPayload(
            point,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
          ),
        ),
      );
      unawaited(_flushPendingLocationUploads());
      return;
    }

    final payload = buildRealtimeLocationPayload(
      point,
      batteryLevel: batteryLevel,
      isCharging: isCharging,
    );
    dev.log('[ws] sending: ${jsonEncode(payload)}', name: 'RemoteBackend');
    try {
      _channel!.sink.add(jsonEncode(payload));
    } catch (_) {
      unawaited(
        _outbox.enqueue(
          buildLocationPayload(
            point,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
          ),
        ),
      );
      unawaited(_flushPendingLocationUploads());
    }
  }

  @override
  Future<bool> sendLocation(UserProfile profile) async {
    final location = profile.lastLocation;
    if (location == null) {
      return false;
    }

    final uri = _apiUri('/api/v1/location');
    final payload = [
      {
        'coords': {
          'latitude': location.latitude,
          'longitude': location.longitude,
          'speed': location.speed,
          'heading': location.heading,
        },
        'timestamp': location.timestamp.toUtc().toIso8601String(),
        if (profile.batteryLevel != null) 'battery_level': profile.batteryLevel,
        if (profile.isCharging != null) 'is_charging': profile.isCharging,
      },
    ];

    final response = await _httpClient.post(
      uri,
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $accessToken',
      },
      body: jsonEncode(payload),
    );

    return response.statusCode >= 200 && response.statusCode < 300;
  }

  @override
  Future<void> registerFcmToken(String token) async {
    final uri = _apiUri('/api/v1/fcm-token');
    try {
      await _httpClient.post(
        uri,
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'token': token}),
      );
    } catch (_) {
      // Non-critical — FCM pacing updates simply won't arrive if this fails.
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _outboxFlushTimer?.cancel();
    _outboxFlushTimer = null;
    _channel?.sink.close();
    _peerController.close();
    _httpClient.close();
  }

  Future<String> _requestTicket() async {
    final uri = _apiUri('/api/v1/streams/ticket');
    final response = await _httpClient.post(
      uri,
      headers: {'authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Unable to obtain streaming ticket');
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
    dev.log('[ws] connecting to $uri', name: 'RemoteBackend');
    _channel = WebSocketChannel.connect(uri);
    _channel!.stream.listen(
      _handleWebSocketMessage,
      onError: (error) {
        dev.log('[ws] error: $error', name: 'RemoteBackend');
        _scheduleReconnect();
      },
      onDone: () {
        dev.log(
          '[ws] connection closed, scheduling reconnect',
          name: 'RemoteBackend',
        );
        _scheduleReconnect();
      },
    );
  }

  Future<void> _connectFreshWebSocket() async {
    if (_disposed) {
      return;
    }

    _ticket = await _requestTicket();
    if (_disposed) {
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

    final latitude = _parseDouble(payload['latitude']);
    final longitude = _parseDouble(payload['longitude']);
    if (latitude == null || longitude == null) {
      return;
    }

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
    profile.lastLocation = point;
    profile.history = [point, ...profile.history].take(20).toList();
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
    if (_disposed) {
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

  Future<void> _flushPendingLocationUploads() async {
    if (_disposed || _flushingOutbox) {
      return;
    }

    _flushingOutbox = true;
    List<Map<String, dynamic>> batch = [];
    try {
      batch = await _outbox.drain();
      if (batch.isEmpty) {
        return;
      }

      final uri = _apiUri('/api/v1/location');
      final response = await _httpClient.post(
        uri,
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(batch),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _outbox.write(batch);
      }
    } catch (error) {
      dev.log('[outbox] flush failed: $error', name: 'RemoteBackend');
      if (batch.isNotEmpty) {
        await _outbox.write(batch);
      }
    } finally {
      _flushingOutbox = false;
    }
  }
}
