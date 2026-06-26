import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../data/models/location_model.dart';

final Map<String, Future<String>> _streetLookupCache = {};

Future<String> streetNameFor(LocationPoint location) {
  final key =
      '${location.latitude.toStringAsFixed(5)},${location.longitude.toStringAsFixed(5)}';
  return _streetLookupCache.putIfAbsent(key, () async {
    try {
      final response = await http.get(
        Uri.https('nominatim.openstreetmap.org', '/reverse', {
          'format': 'jsonv2',
          'lat': location.latitude.toString(),
          'lon': location.longitude.toString(),
          'zoom': '18',
          'addressdetails': '1',
        }),
        headers: const {
          'accept': 'application/json',
          'user-agent': 'legacytracker/1.0',
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return 'Location unavailable';
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final address = payload['address'] as Map<String, dynamic>?;
      final road = _firstNonEmptyString([
        address?['road'],
        address?['pedestrian'],
        address?['footway'],
        address?['path'],
        address?['street'],
      ]);
      final city = _firstNonEmptyString([
        address?['city'],
        address?['town'],
        address?['village'],
        address?['hamlet'],
        address?['suburb'],
        address?['municipality'],
      ]);
      if (road != null) {
        final number = _firstNonEmptyString([
          address?['house_number'],
        ]);
        final street = number != null ? '$road $number' : road;
        if (city != null) {
          return '$street, $city';
        }
        return street;
      }

      if (city != null) {
        return city;
      }

      final displayName = payload['display_name'];
      if (displayName is String && displayName.trim().isNotEmpty) {
        return displayName.trim();
      }

      return 'Location unavailable';
    } catch (_) {
      return 'Location unavailable';
    }
  });
}

String? _firstNonEmptyString(Iterable<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim();
    if (text != null && text.isNotEmpty) {
      return text;
    }
  }
  return null;
}

class LocationStreetLabel extends StatelessWidget {
  const LocationStreetLabel({
    super.key,
    required this.location,
    this.style,
    this.maxLines = 2,
    this.placeholder = 'Looking up location...',
  });

  final LocationPoint location;
  final TextStyle? style;
  final int maxLines;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: streetNameFor(location),
      builder: (context, snapshot) {
        final text = snapshot.data ?? placeholder;
        return Text(
          text,
          style: style ?? Theme.of(context).textTheme.bodySmall,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}
