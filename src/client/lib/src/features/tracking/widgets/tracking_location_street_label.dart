import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../../data/models/location_model.dart';
import '../../../data/network/nominatim.dart';
import '../../checkpoints/checkpoints_provider.dart';

const _unavailable = 'Location unavailable';

// ~11 m, like the web: enough to name the street, coarse enough that GPS
// jitter of a moving peer doesn't cost a lookup per fix.
final LruMap<String, Future<String>> _streetLookupCache = LruMap(300);
final http.Client _streetClient = http.Client();

Future<String> streetNameFor(LocationPoint location) {
  final key =
      '${location.latitude.toStringAsFixed(4)},${location.longitude.toStringAsFixed(4)}';
  final cached = _streetLookupCache[key];
  if (cached != null) return cached;
  final lookup = _lookupStreet(location).then((name) {
    // A failure is not remembered: the next request tries again.
    if (name == _unavailable) _streetLookupCache.remove(key);
    return name;
  });
  _streetLookupCache[key] = lookup;
  return lookup;
}

Future<String> _lookupStreet(LocationPoint location) async {
  try {
    await nominatimThrottle.acquire();
    final response = await _streetClient
        .get(
          nominatimUri('/reverse', {
            'format': 'jsonv2',
            'lat': location.latitude.toString(),
            'lon': location.longitude.toString(),
            'zoom': '18',
            'addressdetails': '1',
          }),
          headers: nominatimHeaders,
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return _unavailable;
    }
    final payload =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return describeAddress(payload) ?? _unavailable;
  } catch (_) {
    return _unavailable;
  }
}

/// The label for a Nominatim reverse-geocoding payload: "road number, city",
/// else the city, else its display name.
String? describeAddress(Map<String, dynamic> payload) {
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
    final number = _firstNonEmptyString([address?['house_number']]);
    final street = number != null ? '$road $number' : road;
    return city != null ? '$street, $city' : street;
  }
  if (city != null) return city;
  final displayName = payload['display_name'];
  if (displayName is String && displayName.trim().isNotEmpty) {
    return displayName.trim();
  }
  return null;
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
    // Nullable lookup: the label also renders where no provider is mounted.
    final checkpoint = context.watch<CheckpointsProvider?>()?.resolve(
      location.latitude,
      location.longitude,
    );
    if (checkpoint != null) {
      final textStyle = style ?? Theme.of(context).textTheme.bodySmall;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.place_rounded,
            size: (textStyle?.fontSize ?? 12) + 2,
            color: textStyle?.color,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              checkpoint.name,
              style: textStyle,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
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
