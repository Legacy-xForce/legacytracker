import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/checkpoint.dart';
import 'api_client.dart';

class CheckpointService {
  CheckpointService({required String baseUrl, http.Client? httpClient})
    : _api = ApiClient(baseUrl: baseUrl, httpClient: httpClient);

  final ApiClient _api;

  Future<List<Checkpoint>> list(String accessToken) async {
    final response = await _api.send(
      () => _api.httpClient.get(_api.uri('/api/v1/checkpoints'), headers: _api.headers(accessToken)),
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
    final response = await _api.send(
      () => _api.httpClient.post(
        _api.uri('/api/v1/checkpoints'),
        headers: _api.headers(accessToken, json: true),
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
    final response = await _api.send(
      () => _api.httpClient.patch(
        _api.uri('/api/v1/checkpoints/$id'),
        headers: _api.headers(accessToken, json: true),
        body: _body(name, latitude, longitude, radiusM),
      ),
    );
    _check(response, expected: 200);
    return Checkpoint.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> delete(String accessToken, String id) async {
    final response = await _api.send(
      () => _api.httpClient.delete(
        _api.uri('/api/v1/checkpoints/$id'),
        headers: _api.headers(accessToken),
      ),
    );
    _check(response, expected: 200);
  }

  String _body(String name, double latitude, double longitude, int radiusM) =>
      jsonEncode({
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'radius_m': radiusM,
      });

  void _check(http.Response response, {required int expected}) {
    if (response.statusCode == expected) return;
    switch (response.statusCode) {
      case 409:
        throw ApiException(
          'A checkpoint with that name already exists.',
          status: 409,
        );
      case 403:
        throw ApiException("You can't change this checkpoint.");
      case 404:
        throw ApiException('This checkpoint no longer exists.');
      case 400:
        throw ApiException(ApiClient.serverMessage(response) ?? 'Invalid checkpoint.');
      default:
        throw ApiException(
          'Something went wrong (${response.statusCode}). Try again.',
        );
    }
  }
}
