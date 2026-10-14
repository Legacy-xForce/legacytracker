import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/checkpoint.dart';

/// A request the server refused, with a message safe to show to the user.
class CheckpointException implements Exception {
  CheckpointException(this.message, {this.nameTaken = false});

  final String message;

  /// The name collides with another checkpoint (HTTP 409).
  final bool nameTaken;

  @override
  String toString() => message;
}

class CheckpointService {
  CheckpointService({required String baseUrl, http.Client? httpClient})
    : _baseUri = Uri.parse(baseUrl),
      _httpClient = httpClient ?? http.Client();

  final Uri _baseUri;
  final http.Client _httpClient;

  Future<List<Checkpoint>> list(String accessToken) async {
    final response = await _send(
      () => _httpClient.get(_uri('/api/v1/checkpoints'), headers: _headers(accessToken)),
    );
    _check(response, expected: 200);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['checkpoints'] as List<dynamic>)
        .map((json) => Checkpoint.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<Checkpoint> create(
    String accessToken, {
    required String name,
    required double latitude,
    required double longitude,
    required int radiusM,
  }) async {
    final response = await _send(
      () => _httpClient.post(
        _uri('/api/v1/checkpoints'),
        headers: _headers(accessToken),
        body: _body(name, latitude, longitude, radiusM),
      ),
    );
    _check(response, expected: 201);
    return Checkpoint.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<Checkpoint> update(
    String accessToken,
    String id, {
    required String name,
    required double latitude,
    required double longitude,
    required int radiusM,
  }) async {
    final response = await _send(
      () => _httpClient.patch(
        _uri('/api/v1/checkpoints/$id'),
        headers: _headers(accessToken),
        body: _body(name, latitude, longitude, radiusM),
      ),
    );
    _check(response, expected: 200);
    return Checkpoint.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> delete(String accessToken, String id) async {
    final response = await _send(
      () => _httpClient.delete(
        _uri('/api/v1/checkpoints/$id'),
        headers: _headers(accessToken),
      ),
    );
    _check(response, expected: 200);
  }

  Uri _uri(String path) => _baseUri.replace(path: path);

  Map<String, String> _headers(String accessToken) => {
    'content-type': 'application/json',
    'authorization': 'Bearer $accessToken',
  };

  String _body(String name, double latitude, double longitude, int radiusM) =>
      jsonEncode({
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'radius_m': radiusM,
      });

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(const Duration(seconds: 15));
    } on Exception {
      throw CheckpointException(
        'Unable to reach the server. Check your connection and try again.',
      );
    }
  }

  void _check(http.Response response, {required int expected}) {
    if (response.statusCode == expected) return;
    switch (response.statusCode) {
      case 409:
        throw CheckpointException(
          'A checkpoint with that name already exists.',
          nameTaken: true,
        );
      case 403:
        throw CheckpointException("You can't change this checkpoint.");
      case 404:
        throw CheckpointException('This checkpoint no longer exists.');
      case 400:
        throw CheckpointException(_serverMessage(response) ?? 'Invalid checkpoint.');
      default:
        throw CheckpointException(
          'Something went wrong (${response.statusCode}). Try again.',
        );
    }
  }

  String? _serverMessage(http.Response response) {
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['error'] as String?;
    } catch (_) {
      return null;
    }
  }
}
