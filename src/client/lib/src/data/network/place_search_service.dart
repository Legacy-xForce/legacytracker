import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class PlaceResult {
  const PlaceResult({required this.label, required this.point});

  final String label;
  final LatLng point;
}

/// Forward geocoding through Nominatim, the same service the street labels
/// already use for reverse lookups. Callers must debounce: the usage policy
/// allows about one request per second.
class PlaceSearchService {
  PlaceSearchService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  Future<List<PlaceResult>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 3) return const [];
    final response = await _httpClient
        .get(
          Uri.https('nominatim.openstreetmap.org', '/search', {
            'format': 'jsonv2',
            'q': trimmed,
            'limit': '6',
          }),
          headers: const {
            'accept': 'application/json',
            'user-agent': 'legacytracker/1.0',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Search failed (${response.statusCode})');
    }
    final items = jsonDecode(response.body) as List<dynamic>;
    return [
      for (final item in items.cast<Map<String, dynamic>>())
        PlaceResult(
          label: (item['display_name'] as String?)?.trim() ?? trimmed,
          point: LatLng(
            double.parse(item['lat'] as String),
            double.parse(item['lon'] as String),
          ),
        ),
    ];
  }
}
