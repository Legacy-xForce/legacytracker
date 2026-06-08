import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_provider.dart';
import '../tracking_controller.dart';
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
    final auth = context.watch<AuthProvider>();
    final profile = auth.profile;
    final notifications = auth.notifications;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TrackingStatusCard(controller: controller),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: controller.isTracking ? controller.stopTracking : controller.startTracking,
            icon: Icon(controller.isTracking ? Icons.pause : Icons.play_arrow),
            label: Text(controller.isTracking ? 'Pause tracking' : 'Resume tracking'),
          ),
          const SizedBox(height: 24),
          Text('Profile', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 38,
                backgroundImage: profile != null && profile.avatarUrl.isNotEmpty
                    ? NetworkImage(profile.avatarUrl)
                    : null,
                child: profile == null || profile.avatarUrl.isEmpty
                    ? Text(
                        profile != null && profile.name.isNotEmpty
                            ? profile.name.characters.first.toUpperCase()
                            : '?',
                        style: const TextStyle(fontSize: 28),
                      )
                    : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile?.name ?? controller.selfProfile.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Username: ${auth.username ?? controller.selfProfile.id}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Role: ${profile?.role ?? controller.selfProfile.role}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Update profile', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Display name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: avatarController,
            decoration: const InputDecoration(
              labelText: 'Avatar URL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onSaveProfile,
              child: const Text('Save profile'),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Notifications', style: Theme.of(context).textTheme.titleMedium),
              TextButton(
                onPressed: auth.refreshNotifications,
                child: const Text('Refresh'),
              ),
            ],
          ),
          if (notifications.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8.0),
              child: Text('No notifications yet.'),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: notifications.length,
              separatorBuilder: (context, index) => const Divider(height: 16),
              itemBuilder: (context, index) {
                final item = notifications[index];
                return ListTile(
                  title: Text(item.content),
                  subtitle: Text(
                    item.createdAt.toLocal().toString(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: TextButton(
                    onPressed: item.read ? null : () => auth.markNotificationRead(item.id),
                    child: Text(item.read ? 'Read' : 'Mark read'),
                  ),
                );
              },
            ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () async {
                await auth.logout();
              },
              child: const Text('Logout'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
