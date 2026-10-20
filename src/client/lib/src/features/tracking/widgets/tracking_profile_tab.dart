import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_provider.dart';
import '../../auth/passkeys_screen.dart';
import '../../checkpoints/checkpoints_screen.dart';
import '../../debug/debug_log_screen.dart';
import '../../updates/app_updater.dart';
import '../../updates/app_updates_card.dart';
import '../local_avatar_store.dart';
import '../map_settings.dart';
import '../tracking_controller.dart';
import 'appearance_card.dart';
import 'tracking_map_layer.dart';
import 'tracking_status_card.dart';
import 'user_avatar.dart';

class TrackingProfileTab extends StatelessWidget {
  const TrackingProfileTab({super.key, required this.controller});

  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final avatarStore = context.watch<LocalAvatarStore>();
    final self = controller.selfProfile;
    final name = auth.username ?? auth.profile?.name ?? self.name;
    final role = auth.profile?.role ?? self.role;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'Profile',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: _AvatarPicker(
              userId: self.id,
              name: name,
              avatarBytes: avatarStore.bytes,
              onTap: () => _showAvatarOptions(context, avatarStore),
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              name,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(child: _RoleChip(role: role)),
          const SizedBox(height: 28),
          const _SectionLabel('Location sharing'),
          TrackingStatusCard(controller: controller),
          const SizedBox(height: 24),
          const _SectionLabel('Appearance'),
          const AppearanceCard(),
          const SizedBox(height: 24),
          const _SectionLabel('Map'),
          const DefaultMapStyleCard(),
          const SizedBox(height: 24),
          const _SectionLabel('Places'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const Icon(Icons.place_outlined),
              title: const Text('Checkpoints'),
              subtitle: const Text('Named places shown instead of the street'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                final last = self.lastLocation;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CheckpointsScreen(
                      initialCenter: last == null
                          ? null
                          : LatLng(last.latitude, last.longitude),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('Sign-in'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const Icon(Icons.fingerprint_rounded),
              title: const Text('Passkeys'),
              subtitle: const Text('Sign in with your fingerprint or screen lock'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const PasskeysScreen())),
            ),
          ),
          if (AppUpdater.isSupported) ...[
            const SizedBox(height: 24),
            const _SectionLabel('App updates'),
            const AppUpdatesCard(),
          ],
          const SizedBox(height: 24),
          const _SectionLabel('Support'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Activity log'),
              subtitle: const Text('Tracking events, for troubleshooting'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const DebugLogScreen())),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(
                Icons.logout_rounded,
                color: theme.colorScheme.error,
              ),
              title: Text(
                'Sign out',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: () => _confirmSignOut(context, auth),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, AuthProvider auth) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your location stops being shared from this phone until you sign '
          'back in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 40),
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed == true) await auth.logout();
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
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = role.isEmpty
        ? 'User'
        : '${role[0].toUpperCase()}${role.substring(1)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({
    required this.userId,
    required this.name,
    required this.avatarBytes,
    required this.onTap,
  });

  final String userId;
  final String name;
  final Uint8List? avatarBytes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Change photo',
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            UserAvatar(
              userId: userId,
              name: name,
              imageBytes: avatarBytes,
              size: 104,
            ),
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 3),
                ),
                child: Icon(
                  Icons.photo_camera_rounded,
                  size: 18,
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks the map style the app opens with.
class DefaultMapStyleCard extends StatelessWidget {
  const DefaultMapStyleCard({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<MapSettings>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Default map style'),
            const SizedBox(height: 4),
            Text(
              'Used whenever the map opens',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<MapLayer>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: MapLayer.standard,
                    icon: Icon(Icons.map_outlined),
                    label: Text('Standard'),
                  ),
                  ButtonSegment(
                    value: MapLayer.satellite,
                    icon: Icon(Icons.satellite_alt_outlined),
                    label: Text('Satellite'),
                  ),
                  ButtonSegment(
                    value: MapLayer.terrain,
                    icon: Icon(Icons.terrain_outlined),
                    label: Text('Terrain'),
                  ),
                ],
                selected: {settings.defaultLayer},
                onSelectionChanged: (s) => settings.setDefaultLayer(s.first),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
