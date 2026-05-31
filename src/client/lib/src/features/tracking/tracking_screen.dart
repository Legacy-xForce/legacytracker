import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/tracking/tracking_controller.dart';
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
  late final TextEditingController _avatarController;
  bool _initialized = false;
  bool _trackingStarted = false;
  int _selectedIndex = 0;
  MapLayer _selectedLayer = MapLayer.standard;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final controller = context.read<TrackingController>();
      _nameController = TextEditingController(
        text: controller.selfProfile.name,
      );
      _avatarController = TextEditingController(
        text: controller.selfProfile.avatarUrl,
      );
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
    _avatarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Legacy Tracker'), centerTitle: true),
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
                onLayerSelected: (layer) =>
                    setState(() => _selectedLayer = layer),
                onUserTap: (user) => showTrackingUserBottomSheet(context, user),
              ),
              TrackingProfileTab(
                controller: controller,
                nameController: _nameController,
                avatarController: _avatarController,
                onSaveProfile: () {
                  controller.updateProfile(
                    name: _nameController.text.trim().isEmpty
                        ? 'You'
                        : _nameController.text.trim(),
                    avatarUrl: _avatarController.text.trim(),
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
    );
  }
}
