import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/auth/auth_provider.dart';
import '../../features/tracking/tracking_controller.dart';
import 'local_avatar_store.dart';
import 'widgets/tracking_map_layer.dart';
import 'widgets/tracking_map_tab.dart';
import 'widgets/tracking_profile_tab.dart';
import 'widgets/tracking_user_bottom_sheet.dart';

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  late final TextEditingController _nameController;
  late final LocalAvatarStore _avatarStore;
  bool _initialized = false;
  bool _trackingStarted = false;
  int _selectedIndex = 0;
  MapLayer _selectedLayer = MapLayer.standard;
  String? _selectedUserId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final controller = context.read<TrackingController>();
      _nameController = TextEditingController(
        text: controller.selfProfile.name,
      );
      _avatarStore = LocalAvatarStore();
      _avatarStore.load(controller.selfProfile.id);
      _initialized = true;
    }

    if (!_trackingStarted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<TrackingController>().startTracking();
      });
      _trackingStarted = true;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _avatarStore.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final title = auth.profile?.name ?? auth.username ?? 'Legacy Tracker';

    return ChangeNotifierProvider<LocalAvatarStore>.value(
      value: _avatarStore,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Legacy Tracker · $title'),
          centerTitle: true,
          actions: [
            Consumer<TrackingController>(
              builder: (context, controller, child) {
                return IconButton(
                  tooltip: controller.isTracking ? 'Pause tracking' : 'Resume tracking',
                  icon: Icon(controller.isTracking ? Icons.pause_circle_outline : Icons.play_circle_outline),
                  onPressed: controller.isTracking ? controller.stopTracking : controller.startTracking,
                );
              },
            ),
          ],
        ),
        body: Consumer<TrackingController>(
          builder: (context, controller, child) {
            return IndexedStack(
              index: _selectedIndex,
              children: [
                TrackingMapTab(
                  isActive: _selectedIndex == 0,
                  center: controller.mapCenter,
                  selectedLayer: _selectedLayer,
                  peers: controller.peers,
                  selfProfile: controller.selfProfile,
                  selfTrackingPaused: !controller.isTracking,
                  selfMissingPermissions: !controller.permissionGranted,
                  selfBatterySavingEnabled:
                      controller.selfProfile.batterySavingEnabled,
                  selectedUserId: _selectedUserId,
                  onLayerSelected: (layer) =>
                      setState(() => _selectedLayer = layer),
                  onUserSelected: (user) {
                    setState(() => _selectedUserId = user.id);
                  },
                  onUserTap: (user) => showTrackingUserBottomSheet(context, user),
                ),
                TrackingProfileTab(
                  controller: controller,
                  nameController: _nameController,
                  onSaveProfile: () async {
                    final updatedName = _nameController.text.trim().isEmpty
                        ? 'You'
                        : _nameController.text.trim();

                    controller.updateProfile(
                      name: updatedName,
                      avatarUrl: controller.selfProfile.avatarUrl,
                    );
                    await auth.updateProfile(
                      name: updatedName,
                      avatarUrl: controller.selfProfile.avatarUrl,
                    );
                  },
                ),
              ],
            );
          },
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (index) =>
              setState(() => _selectedIndex = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map),
              label: 'Map',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
