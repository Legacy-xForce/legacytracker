import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_provider.dart';
import '../../debug/debug_log_screen.dart';
import '../local_avatar_store.dart';
import '../tracking_controller.dart';

class TrackingProfileTab extends StatelessWidget {
  const TrackingProfileTab({
    super.key,
    required this.controller,
    required this.nameController,
    required this.onSaveProfile,
  });

  final TrackingController controller;
  final TextEditingController nameController;
  final VoidCallback onSaveProfile;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final avatarStore = context.watch<LocalAvatarStore>();
    final profile = auth.profile;
    final displayName = profile?.name ?? controller.selfProfile.name;

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 24.0),
          child: Column(
            children: [
              _AvatarPicker(
                avatarBytes: avatarStore.bytes,
                displayName: displayName,
                onTap: () => _showAvatarOptions(context, avatarStore),
              ),
              const SizedBox(height: 16),
              Text(displayName, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                'Username: ${auth.username ?? controller.selfProfile.id}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Text(
                'Role: ${profile?.role ?? controller.selfProfile.role}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 32),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Display name', style: Theme.of(context).textTheme.titleMedium),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Display name',
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
              const SizedBox(height: 32),
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
        ),
        Positioned(
          right: 16,
          bottom: 0,
          child: FloatingActionButton(
            heroTag: 'debug_log_fab',
            tooltip: 'Activity log',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DebugLogScreen()),
              );
            },
            child: const Icon(Icons.bug_report_outlined),
          ),
        ),
      ],
    );
  }

  Future<void> _showAvatarOptions(
    BuildContext context,
    LocalAvatarStore avatarStore,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  avatarStore.pickImage(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  avatarStore.pickImage(ImageSource.camera);
                },
              ),
              if (avatarStore.bytes != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Remove photo'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    avatarStore.clear();
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({
    required this.avatarBytes,
    required this.displayName,
    required this.onTap,
  });

  final Uint8List? avatarBytes;
  final String displayName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          CircleAvatar(
            radius: 48,
            backgroundImage: avatarBytes != null ? MemoryImage(avatarBytes!) : null,
            child: avatarBytes == null
                ? Text(
                    displayName.isNotEmpty ? displayName.characters.first.toUpperCase() : '?',
                    style: const TextStyle(fontSize: 32),
                  )
                : null,
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
              child: Icon(
                Icons.camera_alt,
                size: 16,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
