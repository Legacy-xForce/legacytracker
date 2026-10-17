import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/navigation.dart';
import '../../data/models/calendar_event.dart';
import '../tracking/widgets/user_avatar.dart';

/// Fallback when the calendar gives an event no color.
const eventFallbackColor = Color(0xFF7C4DFF);

/// A rounded-square calendar pin in the event's color — deliberately unlike
/// the round avatars of people.
class EventMarker extends StatelessWidget {
  const EventMarker({super.key, required this.event, required this.onTap});

  static const double size = 44;

  final CalendarEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = event.color ?? eventFallbackColor;
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return Tooltip(
      message: event.title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: const [
                BoxShadow(color: Color(0x66000000), blurRadius: 6),
              ],
            ),
            child: SizedBox.square(
              dimension: 36,
              child: Icon(Icons.event_rounded, size: 22, color: onColor),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showEventDetails(BuildContext context, CalendarEvent event) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => EventDetailsSheet(event: event),
  );
}

/// Name, time until it starts (or ends, once running) and who is coming.
class EventDetailsSheet extends StatefulWidget {
  const EventDetailsSheet({super.key, required this.event});

  final CalendarEvent event;

  @override
  State<EventDetailsSheet> createState() => _EventDetailsSheetState();
}

class _EventDetailsSheetState extends State<EventDetailsSheet> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 30),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _timing(DateTime now) {
    final event = widget.event;
    if (event.isOver(now)) return 'Ended';
    if (event.isRunning(now)) {
      return event.endTime == null
          ? 'Happening now'
          : 'Happening now · ends in ${formatUntil(event.endTime!.difference(now))}';
    }
    return 'Starts in ${formatUntil(event.startTime.difference(now))}';
  }

  Future<void> _openInCalendar() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = widget.event.webUri(AppConstants.calendarWebUrl);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // Falls through to the message below.
    }
    if (!opened) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not open Legacy Calendar.')),
      );
    }
  }

  /// Opens the maps app with directions to the event: its resolved point when
  /// there is one, otherwise the location text.
  Future<void> _go() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final event = widget.event;
    final point = event.point;
    final apple = defaultTargetPlatform == TargetPlatform.iOS;
    final uri = point != null
        ? directionsUri(point.latitude, point.longitude, apple: apple)
        : directionsToUri(event.location!, apple: apple);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // Falls through to the message below.
    }
    if (!opened) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not open the maps app.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final theme = Theme.of(context);
    final attendees = event.attendees;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: event.color ?? eventFallbackColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(event.title, style: theme.textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_timing(DateTime.now()), style: theme.textTheme.titleSmall),
            if (event.location != null) ...[
              const SizedBox(height: 4),
              Text(
                event.location!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              attendees.isEmpty ? 'Nobody yet' : '${attendees.length} going',
              style: theme.textTheme.labelLarge,
            ),
            if (attendees.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  for (final person in attendees)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        UserAvatar(
                          userId: person.id,
                          name: person.name,
                          avatarUrl: person.avatarUrl,
                          size: 28,
                        ),
                        const SizedBox(width: 6),
                        Text(person.name),
                      ],
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                if (event.point != null || event.location != null)
                  FilledButton.icon(
                    onPressed: _go,
                    icon: const Icon(Icons.directions_rounded, size: 18),
                    label: const Text('Go'),
                  ),
                TextButton.icon(
                  onPressed: _openInCalendar,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open in Legacy Calendar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
