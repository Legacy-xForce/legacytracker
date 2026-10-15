import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../features/tracking/tracking_controller.dart';
import 'local_avatar_store.dart';
import 'widgets/tracking_map_layer.dart';
import 'widgets/tracking_map_tab.dart';
import 'widgets/tracking_profile_tab.dart';

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  static const _mapTab = 0;
  static const _profileTab = 1;

  late final LocalAvatarStore _avatarStore;
  bool _initialized = false;
  bool _trackingStarted = false;
  int _selectedIndex = _mapTab;
  MapLayer _selectedLayer = MapLayer.standard;
  String? _selectedUserId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final controller = context.read<TrackingController>();
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
    _avatarStore.dispose();
    super.dispose();
  }

  void _selectTab(int index) {
    setState(() => _selectedIndex = index);
    context.read<TrackingController>().setMapTabSelected(index == _mapTab);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<LocalAvatarStore>.value(
      value: _avatarStore,
      // The map runs edge to edge under the status bar, so its icons have to
      // stay light over the dark scrim there.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
        ),
        child: Scaffold(
          body: Consumer<TrackingController>(
            builder: (context, controller, child) {
              return IndexedStack(
                index: _selectedIndex,
                children: [
                  TrackingMapTab(
                    isActive: _selectedIndex == _mapTab,
                    center: controller.mapCenter,
                    selectedLayer: _selectedLayer,
                    peers: controller.peers,
                    selfProfile: controller.selfProfile,
                    selfTrackingPaused: !controller.isTracking,
                    selfMissingPermissions: !controller.permissionGranted,
                    selfBatterySavingEnabled:
                        controller.selfProfile.batterySavingEnabled,
                    selfLive: controller.status.live,
                    viewers: controller.viewers,
                    selectedUserId: _selectedUserId,
                    onLayerSelected: (layer) =>
                        setState(() => _selectedLayer = layer),
                    onUserSelected: (user) {
                      setState(() => _selectedUserId = user.id);
                    },
                    onStatusTap: () => _selectTab(_profileTab),
                  ),
                  TrackingProfileTab(controller: controller),
                ],
              );
            },
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: _selectTab,
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
      ),
    );
  }
}
