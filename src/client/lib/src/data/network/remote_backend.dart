import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../data/models/location_model.dart';
import '../../data/models/user_model.dart';
import 'backend.dart';

class RemoteBackend implements Backend {
  RemoteBackend({required this.baseUrl, required this.accessToken, required this.selfId});

  final String baseUrl;
  final String accessToken;
  final String selfId;
  final http.Client _httpClient = http.Client();
  final StreamController<List<UserProfile>> _peerController = StreamController<List<UserProfile>>.broadcast();
  final Map<String, UserProfile> _peerCache = {};
  WebSocketChannel? _channel;
  String? _ticket;
  bool _initialized = false;

  @override
  Stream<List<UserProfile>> get peerStream => _peerController.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    _ticket = await _requestTicket();
    _connectWebSocket();
    _initialized = true;
  }

  @override
  void sendLocationRealtime(LocationPoint point) {
    if (_channel == null) return;
    final payload = {
      'type': 'location',
      'coords': {
        'latitude': point.latitude,
        'longitude': point.longitude,
        'speed': point.speed,
        'heading': point.heading,
      },
      'timestamp': point.timestamp.toUtc().toIso8601String(),
    };
    dev.log('[ws] sending: ${jsonEncode(payload)}', name: 'RemoteBackend');
    _channel!.sink.add(jsonEncode(payload));
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
      }
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
    _channel?.sink.close();
    _peerController.close();
    _httpClient.close();
  }

  Future<String> _requestTicket() async {
    final uri = _apiUri('/api/v1/streams/ticket');
    final response = await _httpClient.post(
      uri,
      headers: {
        'authorization': 'Bearer $accessToken',
      },
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
        dev.log('[ws] connection closed, scheduling reconnect', name: 'RemoteBackend');
        _scheduleReconnect();
      },
    );
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
    final recordedAt = DateTime.tryParse(payload['recorded_at'] as String? ?? '') ?? DateTime.now();

    final point = LocationPoint(
      latitude: latitude,
      longitude: longitude,
      speed: speed,
      heading: heading,
      timestamp: recordedAt,
    );

    final existingProfile = _peerCache[remoteUserId];
    final profile = existingProfile ?? UserProfile(id: remoteUserId, name: remoteUserId, avatarUrl: '');
    profile.lastLocation = point;
    profile.history = [point, ...profile.history].take(20).toList();
    _peerCache[remoteUserId] = profile;
    _peerController.add(List<UserProfile>.unmodifiable(_peerCache.values.toList()));
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
    return target.replace(
      path: path,
      queryParameters: null,
    );
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
    _channel = null;
    dev.log('[ws] reconnecting in 3s', name: 'RemoteBackend');
    Future.delayed(const Duration(seconds: 3), () {
      if (_ticket != null) {
        _connectWebSocket();
      }
    });
  }
}
