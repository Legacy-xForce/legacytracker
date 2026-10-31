import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../features/tracking/tracking_controller.dart';
import '../../data/network/mapbox_token_service.dart';
import '../auth/auth_provider.dart';
import '../travel/travel_tab.dart';
import 'local_avatar_store.dart';
import 'map_settings.dart';
import 'map_variant.dart';
import 'widgets/selection_back_guard.dart';
import 'widgets/tracking_map_layer.dart';
import 'widgets/tracking_map_tab.dart';
import 'widgets/tracking_profile_tab.dart';
import '../../core/palette.dart';

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  static const _mapTab = 0;
  static const _travelTab = 1;

  late final LocalAvatarStore _avatarStore;
  late final MapSettings _mapSettings;
  late final MapboxTokenService _mapboxTokenService;
  bool _initialized = false;
  bool _trackingStarted = false;
  int _selectedIndex = _mapTab;
  // A style picked on the map itself; null follows the default setting.
  MapLayer? _layerOverride;
  String? _selectedUserId;
  // Lets the back gesture tell the map tab to fold the sheet too, which is
  // the tab's own controller animation, not something props can express.
  final GlobalKey<TrackingMapTabState> _mapTabKey =
      GlobalKey<TrackingMapTabState>();

  /// Auto's time band is re-checked every minute, so the map drifts from
  /// dusk into night on its own while it stays open.
  Timer? _variantTicker;
  DateTime _now = DateTime.now();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final controller = context.read<TrackingController>();
      _avatarStore = LocalAvatarStore();
      _avatarStore.load(controller.selfProfile.id);
      // Changing the default in the profile applies to the map right away.
      _mapSettings = context.read<MapSettings>()
        ..addListener(_followDefaultLayer);
      _mapboxTokenService = MapboxTokenService(
        baseUrl: controller.baseUrl,
        getAccessToken: () => context.read<AuthProvider>().accessToken,
      );
      _variantTicker = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() => _now = DateTime.now());
      });
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
    _variantTicker?.cancel();
    _mapboxTokenService.dispose();
    _mapSettings.removeListener(_followDefaultLayer);
    _avatarStore.dispose();
    super.dispose();
  }

  void _followDefaultLayer() {
    if (_layerOverride != null) setState(() => _layerOverride = null);
  }

  void _selectTab(int index) {
    setState(() => _selectedIndex = index);
    context.read<TrackingController>().setMapTabSelected(index == _mapTab);
  }

  void _clearSelection() {
    if (_selectedUserId == null) return;
    setState(() => _selectedUserId = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return ChangeNotifierProvider<LocalAvatarStore>.value(
      value: _avatarStore,
      // The map runs edge to edge under the status bar, so its icons have to
      // stay light over the dark scrim there (and dark on a light theme).
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(
              statusBarColor: AppPalette.transparent,
              systemNavigationBarColor: theme.colorScheme.surface,
              systemNavigationBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
            ),
        child: SelectionBackGuard(
          consumeBack: _selectedIndex != _mapTab || _selectedUserId != null,
          onBack: () {
            if (_selectedIndex != _mapTab) {
              _selectTab(_mapTab);
            } else {
              final tab = _mapTabKey.currentState;
              if (tab != null) {
                tab.clearSelectionAndCollapse();
              } else {
                _clearSelection();
              }
            }
          },
          child: Scaffold(
            body: Consumer2<TrackingController, MapSettings>(
              builder: (context, controller, mapSettings, child) {
                return IndexedStack(
                  index: _selectedIndex,
                  children: [
                    TrackingMapTab(
                      key: _mapTabKey,
                      isActive: _selectedIndex == _mapTab,
                      center: controller.mapCenter,
                      centerIsKnown: controller.hasKnownLocation,
                      selectedLayer:
                          _layerOverride ?? mapSettings.defaultLayer,
                      lightPreset: resolveMapPreset(
                        mapSettings.mapVariant,
                        _now,
                      ),
                      peers: controller.peers,
                      selfProfile: controller.selfProfile,
                      selfTrackingPaused: !controller.isTracking,
                      selfMissingPermissions: !controller.permissionGranted,
                      selfBatterySavingEnabled:
                          controller.selfProfile.batterySavingEnabled,
                      viewers: controller.viewers,
                      selectedUserId: _selectedUserId,
                      mapboxTokenService: _mapboxTokenService,
                      onLayerSelected: (layer) =>
                          setState(() => _layerOverride = layer),
                      onUserSelected: (user) {
                        setState(() => _selectedUserId = user.id);
                      },
                      onSelectionCleared: _clearSelection,
                    ),
                    TravelTab(
                      isActive: _selectedIndex == _travelTab,
                      selfId: controller.selfProfile.id,
                      baseUrl: controller.baseUrl,
                      getAccessToken: () =>
                          context.read<AuthProvider>().accessToken,
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
                  icon: Icon(Icons.directions_car_outlined),
                  selectedIcon: Icon(Icons.directions_car),
                  label: 'Travel',
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
      ),
    );
  }
}
