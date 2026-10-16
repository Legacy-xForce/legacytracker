import 'package:flutter/painting.dart';
import 'package:latlong2/latlong.dart';

/// Someone who accepted an event, as the calendar describes them.
class EventAttendee {
  const EventAttendee({
    required this.id,
    required this.name,
    this.avatarUrl = '',
  });

  final String id;
  final String name;
  final String avatarUrl;
}

/// An event from Legacy Calendar. [point] is where its free-text [location]
/// resolved to on the map; null until it has been (or if it never can be).
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.startTime,
    this.endTime,
    this.color,
    this.location,
    this.attendees = const [],
    this.point,
  });

  final String id;
  final String title;
  final DateTime startTime;
  final DateTime? endTime;
  final Color? color;
  final String? location;

  /// The host plus everyone who accepted.
  final List<EventAttendee> attendees;
  final LatLng? point;

  /// When the event stops being worth showing: its end, or midnight at the
  /// end of the day it starts when the calendar gives no end.
  DateTime get shownUntil {
    final end = endTime;
    if (end != null) return end;
    final start = startTime.toLocal();
    return DateTime(start.year, start.month, start.day + 1);
  }

  bool isOver(DateTime now) => !now.isBefore(shownUntil);

  bool isRunning(DateTime now) => !now.isBefore(startTime) && !isOver(now);

  /// The event's page in the Legacy Calendar web app, under [baseUrl].
  Uri webUri(String baseUrl) {
    final base = Uri.parse(baseUrl);
    final path = base.path.replaceFirst(RegExp(r'/+$'), '');
    return base.replace(path: '$path/event/${Uri.encodeComponent(id)}');
  }

  CalendarEvent withPoint(LatLng? point) => CalendarEvent(
    id: id,
    title: title,
    startTime: startTime,
    endTime: endTime,
    color: color,
    location: location,
    attendees: attendees,
    point: point,
  );

  /// Null when the event is unusable (no id, title or start time).
  static CalendarEvent? tryParse(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    final start = DateTime.tryParse('${json['startTime']}');
    if (id == null || title is! String || start == null) return null;

    final attendees = <String, EventAttendee>{};
    void add(Object? user) {
      if (user is! Map || user['id'] == null) return;
      final attendee = EventAttendee(
        id: '${user['id']}',
        name: '${user['username'] ?? ''}',
        avatarUrl: user['profilePictureUrl'] is String
            ? user['profilePictureUrl'] as String
            : '',
      );
      attendees.putIfAbsent(attendee.id, () => attendee);
    }

    add(json['host']);
    for (final participant in (json['participants'] as List?) ?? const []) {
      if (participant is Map && participant['status'] == 'ACCEPTED') {
        add(participant);
      }
    }

    final location = json['location'];
    return CalendarEvent(
      id: '$id',
      title: title.trim().isEmpty ? 'Untitled event' : title.trim(),
      startTime: start,
      endTime: DateTime.tryParse('${json['endTime']}'),
      color: parseHexColor(json['color']),
      location: location is String && location.trim().isNotEmpty
          ? location.trim()
          : null,
      attendees: attendees.values.toList(),
    );
  }
}

/// "#rrggbb" or "#rgb" (leading # optional); null for anything else.
Color? parseHexColor(Object? value) {
  if (value is! String) return null;
  var hex = value.trim().replaceFirst('#', '');
  if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex, radix: 16));
}
