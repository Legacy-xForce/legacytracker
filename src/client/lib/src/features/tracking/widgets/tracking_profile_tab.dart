import 'package:flutter/material.dart';

import '../tracking_controller.dart';
import 'tracking_history_section.dart';
import 'tracking_profile_editor.dart';
import 'tracking_status_card.dart';

class TrackingProfileTab extends StatelessWidget {
  const TrackingProfileTab({
    super.key,
    required this.controller,
    required this.nameController,
    required this.avatarController,
    required this.onSaveProfile,
  });

  final TrackingController controller;
  final TextEditingController nameController;
  final TextEditingController avatarController;
  final VoidCallback onSaveProfile;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TrackingStatusCard(controller: controller),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: controller.isTracking
                ? controller.stopTracking
                : controller.startTracking,
            icon: Icon(controller.isTracking ? Icons.pause : Icons.play_arrow),
            label: Text(
              controller.isTracking ? 'Pause tracking' : 'Resume tracking',
            ),
          ),
          const SizedBox(height: 16),
          TrackingProfileEditor(
            nameController: nameController,
            avatarController: avatarController,
            onSaveProfile: onSaveProfile,
          ),
          const SizedBox(height: 24),
          Text(
            'Tracking history',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          TrackingHistorySection(history: controller.history),
        ],
      ),
    );
  }
}
