import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../../data/models/user_model.dart';
import '../../features/tracking/tracking_controller.dart';

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

enum MapLayer { standard, satellite, terrain }

class _TrackingScreenState extends State<TrackingScreen> {
  final MapController _mapController = MapController();
  LatLng? _lastCenteredLocation;
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
      _nameController = TextEditingController(text: controller.selfProfile.name);
      _avatarController = TextEditingController(text: controller.selfProfile.avatarUrl);
      _initialized = true;
    }

    if (!_trackingStarted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final controller = context.read<TrackingController>();
        controller.startTracking();
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

  List<Widget> _getMapLayers() {
    switch (_selectedLayer) {
      case MapLayer.satellite:
        return [
          TileLayer(
            urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
            userAgentPackageName: 'com.example.legacytracker',
          ),
          TileLayer(
            urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
            userAgentPackageName: 'com.example.legacytracker',
          ),
        ];
      case MapLayer.terrain:
        return [
          TileLayer(
            urlTemplate: 'https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}',
            userAgentPackageName: 'com.example.legacytracker',
          ),
        ];
      case MapLayer.standard:
        return [
          TileLayer(
            urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
            subdomains: const ['a', 'b', 'c'],
            userAgentPackageName: 'com.example.legacytracker',
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Legacy Tracker'),
        centerTitle: true,
      ),
      body: Consumer<TrackingController>(
        builder: (context, controller, child) {
          final center = controller.lastLocation != null
              ? LatLng(controller.lastLocation!.latitude, controller.lastLocation!.longitude)
              : AppConstants.defaultMapCenter;

          if (_selectedIndex == 0 && controller.lastLocation != null) {
            final latestLocation = LatLng(controller.lastLocation!.latitude, controller.lastLocation!.longitude);
            if (_lastCenteredLocation != latestLocation) {
              _lastCenteredLocation = latestLocation;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _mapController.move(latestLocation, AppConstants.defaultZoom);
              });
            }
          }

          return Stack(
            children: [
              IndexedStack(
                index: _selectedIndex,
                children: [
                  _buildMapTab(controller, center),
                  _buildProfileTab(controller),
                ],
              ),
              if (_selectedIndex == 0)
                Positioned(
                  top: 16,
                  right: 16,
                  child: PopupMenuButton<MapLayer>(
                    initialValue: _selectedLayer,
                    onSelected: (layer) => setState(() => _selectedLayer = layer),
                    itemBuilder: (BuildContext context) => [
                      const PopupMenuItem(
                        value: MapLayer.standard,
                        child: Text('Standard'),
                      ),
                      const PopupMenuItem(
                        value: MapLayer.satellite,
                        child: Text('Satellite'),
                      ),
                      const PopupMenuItem(
                        value: MapLayer.terrain,
                        child: Text('Terrain'),
                      ),
                    ],
                    child: FloatingActionButton(
                      mini: true,
                      child: const Icon(Icons.layers),
                      onPressed: null,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
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

  Widget _buildMapTab(TrackingController controller, LatLng center) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: AppConstants.defaultZoom,
        minZoom: AppConstants.minZoom,
        maxZoom: AppConstants.maxZoom,
        keepAlive: true,
      ),
      children: [
        ..._getMapLayers(),
        MarkerLayer(
          markers: [
            ..._buildPeerMarkers(controller.peers),
            if (controller.selfProfile.lastLocation != null)
              _buildSelfMarker(controller.selfProfile),
          ],
        ),
      ],
    );
  }

  Widget _buildProfileTab(TrackingController controller) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusCard(controller),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: controller.isTracking ? controller.stopTracking : controller.startTracking,
            icon: Icon(controller.isTracking ? Icons.pause : Icons.play_arrow),
            label: Text(controller.isTracking ? 'Pause tracking' : 'Resume tracking'),
          ),
          const SizedBox(height: 16),
          _buildProfileEditor(controller),
          const SizedBox(height: 24),
          Text('Tracking history', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...controller.history.take(6).map((point) => ListTile(
                title: Text('${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}'),
                subtitle: Text('${point.timestamp.hour}:${point.timestamp.minute.toString().padLeft(2, '0')} • ${point.speed.toStringAsFixed(1)} m/s'),
              )),
        ],
      ),
    );
  }

  Widget _buildStatusCard(TrackingController controller) {
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
                Text(controller.permissionGranted ? 'Location allowed' : 'Permission needed'),
                Text(controller.isTracking ? 'Tracking on' : 'Tracking paused'),
                Text('Speed: ${controller.speedLabel}'),
                Text('Moving: ${controller.isMoving ? 'Yes' : 'No'}'),
              ],
            ),
            CircleAvatar(
              radius: 28,
              backgroundColor: Colors.teal.shade100,
              child: Text(
                controller.selfProfile.name.characters.first.toUpperCase(),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileEditor(TrackingController controller) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your profile', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Display name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _avatarController,
            decoration: const InputDecoration(
              labelText: 'Avatar image URL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    controller.updateProfile(
                      name: _nameController.text.trim().isEmpty ? 'You' : _nameController.text.trim(),
                      avatarUrl: _avatarController.text.trim(),
                    );
                  },
                  child: const Text('Save profile'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('Peer count: ${controller.peers.length}'),
        ],
      ),
    );
  }

  List<Marker> _buildPeerMarkers(List<UserProfile> peers) {
    return peers.map((peer) {
      if (peer.lastLocation == null) {
        return Marker(
          point: AppConstants.defaultMapCenter,
          width: 0,
          height: 0,
          child: const SizedBox.shrink(),
        );
      }
      return Marker(
        point: LatLng(peer.lastLocation!.latitude, peer.lastLocation!.longitude),
        width: 54,
        height: 54,
        child: GestureDetector(
          onTap: () => _showUserBottomSheet(peer),
          child: Tooltip(
            message: peer.name,
            child: CircleAvatar(
              radius: 26,
              backgroundColor: Colors.white,
              child: CircleAvatar(
                radius: 24,
                backgroundImage: peer.avatarUrl.isNotEmpty ? NetworkImage(peer.avatarUrl) : null,
                child: peer.avatarUrl.isEmpty ? Text(peer.name.characters.first.toUpperCase()) : null,
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  Marker _buildSelfMarker(UserProfile profile) {
    return Marker(
      point: LatLng(profile.lastLocation!.latitude, profile.lastLocation!.longitude),
      width: 60,
      height: 60,
      child: GestureDetector(
        onTap: () => _showUserBottomSheet(profile),
        child: Tooltip(
          message: '${profile.name} (you)',
          child: CircleAvatar(
            radius: 30,
            backgroundColor: Colors.teal,
            child: CircleAvatar(
              radius: 26,
              backgroundColor: Colors.white,
              backgroundImage: profile.avatarUrl.isNotEmpty ? NetworkImage(profile.avatarUrl) : null,
              child: profile.avatarUrl.isEmpty ? Text(profile.name.characters.first.toUpperCase()) : null,
            ),
          ),
        ),
      ),
    );
  }

  void _showUserBottomSheet(UserProfile user) {
    final loc = user.lastLocation;
    if (loc == null) return;
    showModalBottomSheet(
      context: context,
      barrierColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12.0)),
      ),
      builder: (ctx) {
        final duration = DateTime.now().difference(loc.timestamp);
        final coords = '${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)}';
        final speedLabel = '${loc.speed.toStringAsFixed(1)} m/s';
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
                    backgroundImage: user.avatarUrl.isNotEmpty ? NetworkImage(user.avatarUrl) : null,
                    child: user.avatarUrl.isEmpty ? Text(user.name.characters.first.toUpperCase()) : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(coords, style: Theme.of(context).textTheme.bodySmall),
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
              const SizedBox(height: 14),
              ElevatedButton.icon(
                onPressed: () async {
                  final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${loc.latitude},${loc.longitude}&travelmode=driving');
                  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open Maps')));
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

  String _formatDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    return '${d.inSeconds}s';
  }
}
