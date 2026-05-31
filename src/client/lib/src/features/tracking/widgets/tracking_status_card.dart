import 'package:flutter/material.dart';

import '../tracking_controller.dart';

class TrackingStatusCard extends StatelessWidget {
  const TrackingStatusCard({super.key, required this.controller});

  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    final initials = controller.selfProfile.name.characters.first.toUpperCase();

    return Card(
      margin: const EdgeInsets.all(12.0),
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Status', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  controller.permissionGranted
                      ? 'Location allowed'
                      : 'Permission needed',
                ),
                Text(controller.isTracking ? 'Tracking on' : 'Tracking paused'),
                Text('Speed: ${controller.speedLabel}'),
                Text('Moving: ${controller.isMoving ? 'Yes' : 'No'}'),
              ],
            ),
            CircleAvatar(
              radius: 28,
              backgroundColor: Colors.teal.shade100,
              child: Text(
                initials,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
