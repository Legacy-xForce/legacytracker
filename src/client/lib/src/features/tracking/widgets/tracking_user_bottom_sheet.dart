import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/models/user_model.dart';
import 'tracking_location_street_label.dart';

Future<void> showTrackingUserBottomSheet(
  BuildContext context,
  UserProfile user,
) async {
  final loc = user.lastLocation;
  if (loc == null) return;

  showModalBottomSheet(
    context: context,
    barrierColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12.0)),
    ),
    builder: (sheetContext) {
      final duration = DateTime.now().difference(loc.timestamp);
      final speedLabel = '${loc.speed.toStringAsFixed(1)} m/s';
      final batteryLabel = user.batteryLevel == null
          ? 'Battery unavailable'
          : 'Battery: ${user.batteryLevel}%';

      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundImage: user.avatarUrl.isNotEmpty
                      ? NetworkImage(user.avatarUrl)
                      : null,
                  child: user.avatarUrl.isEmpty
                      ? Text(user.name.characters.first.toUpperCase())
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.name,
                        style: Theme.of(sheetContext).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      LocationStreetLabel(
                        location: loc,
                        style: Theme.of(sheetContext).textTheme.bodySmall,
                        maxLines: 2,
                        placeholder: 'Looking up street...',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: Text('Speed: $speedLabel')),
                Expanded(child: Text('Here: ${_formatDuration(duration)}')),
              ],
            ),
            const SizedBox(height: 6),
            Text(batteryLabel),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: () async {
                final uri = Uri.parse(
                  'https://www.google.com/maps/dir/?api=1&destination=${loc.latitude},${loc.longitude}&travelmode=driving',
                );
                final opened = await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
                if (!sheetContext.mounted) {
                  return;
                }
                if (!opened) {
                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                    const SnackBar(content: Text('Could not open Maps')),
                  );
                }
              },
              icon: const Icon(Icons.directions),
              label: const Text('Get directions'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

String _formatDuration(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
  }
  return '${duration.inSeconds}s';
}
