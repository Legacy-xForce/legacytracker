import 'package:flutter/material.dart';

import '../../../data/models/user_model.dart';
import 'tracking_location_street_label.dart';

class TrackingUsersDrawer extends StatefulWidget {
  const TrackingUsersDrawer({
    super.key,
    required this.selfProfile,
    required this.peers,
    required this.selfTrackingPaused,
    required this.selfMissingPermissions,
    required this.selfBatterySavingEnabled,
    required this.selectedUserId,
    required this.onUserSelected,
  });

  final UserProfile selfProfile;
  final List<UserProfile> peers;
  final bool selfTrackingPaused;
  final bool selfMissingPermissions;
  final bool selfBatterySavingEnabled;
  final String? selectedUserId;
  final ValueChanged<UserProfile> onUserSelected;

  @override
  State<TrackingUsersDrawer> createState() => _TrackingUsersDrawerState();
}

class _TrackingUsersDrawerState extends State<TrackingUsersDrawer> {
  static const double _collapsedSize = 0.055;
  static const double _expandedSize = 0.6;

  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  double _sheetSize = _collapsedSize;

  @override
  void initState() {
    super.initState();
    _sheetController.addListener(_handleSheetChanged);
  }

  @override
  void dispose() {
    _sheetController.removeListener(_handleSheetChanged);
    _sheetController.dispose();
    super.dispose();
  }

  void _handleSheetChanged() {
    final size = _sheetController.size;
    if ((size - _sheetSize).abs() > 0.001 && mounted) {
      setState(() => _sheetSize = size);
    }
  }

  void _dragSheet(double delta, double screenHeight) {
    if (screenHeight <= 0) {
      return;
    }

    final nextSize = (_sheetController.size - (delta / screenHeight)).clamp(
      _collapsedSize,
      _expandedSize,
    );
    _sheetController.jumpTo(nextSize);
  }

  Future<void> _settleSheet(DragEndDetails details) async {
    final velocity = details.primaryVelocity ?? 0;
    final size = _sheetController.size;

    // 15% of total range defines the snap zone at each end.
    const snapZone = (_expandedSize - _collapsedSize) * 0.15;
    final bottomThreshold = _collapsedSize + snapZone;
    final topThreshold = _expandedSize - snapZone;

    double? target;
    if (velocity > 650) {
      target = _collapsedSize;
    } else if (velocity < -650) {
      target = _expandedSize;
    } else if (size <= bottomThreshold) {
      target = _collapsedSize;
    } else if (size >= topThreshold) {
      target = _expandedSize;
    }
    // Middle zone: no snap — sheet rests at the released position.

    if (target != null) {
      await _sheetController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = [
      _DrawerUser(
        profile: widget.selfProfile,
        isSelf: true,
        trackingPaused: widget.selfTrackingPaused,
        missingPermissions: widget.selfMissingPermissions,
        batterySavingEnabled: widget.selfBatterySavingEnabled,
        batteryLevel: widget.selfProfile.batteryLevel,
      ),
      ...widget.peers.map(
        (peer) => _DrawerUser(
          profile: peer,
          trackingPaused: peer.locationTrackingPaused,
          missingPermissions: peer.missingPermissions,
          batterySavingEnabled: peer.batterySavingEnabled,
          batteryLevel: peer.batteryLevel,
        ),
      ),
    ];

    return Align(
      alignment: Alignment.bottomCenter,
      child: DraggableScrollableSheet(
        controller: _sheetController,
        initialChildSize: _collapsedSize,
        minChildSize: _collapsedSize,
        maxChildSize: _expandedSize,
        expand: false,
        builder: (context, scrollController) {
          final theme = Theme.of(context);
          final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
          return Material(
            color: theme.colorScheme.surface.withValues(alpha: 0.97),
            elevation: 14,
            shadowColor: Colors.black.withValues(alpha: 0.24),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final handleHeight = constraints.maxHeight.clamp(0.0, 40.0);
                  return Column(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: (details) {
                      _dragSheet(
                        details.primaryDelta ?? 0,
                        MediaQuery.sizeOf(context).height,
                      );
                    },
                    onVerticalDragEnd: _settleSheet,
                    child: SizedBox(
                      width: double.infinity,
                      height: handleHeight,
                      child: Center(
                        child: Container(
                          width: 58,
                          height: 6,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: IgnorePointer(
                      ignoring: _sheetSize <= (_collapsedSize + 0.01),
                      child: AnimatedOpacity(
                        opacity:
                            ((_sheetSize - _collapsedSize) /
                                    ((_expandedSize - _collapsedSize) * 0.15))
                                .clamp(0.0, 1.0),
                        duration: const Duration(milliseconds: 80),
                        curve: Curves.easeOut,
                        child: ListView(
                          controller: scrollController,
                          padding: EdgeInsets.fromLTRB(
                            0,
                            2,
                            0,
                            16 + bottomInset,
                          ),
                          children: [
                            const SizedBox(height: 2),
                            ...users.expand(
                              (user) => [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: _UserRow(
                                    user: user,
                                    isSelected:
                                        widget.selectedUserId ==
                                        user.profile.id,
                                    onSelect: () =>
                                        widget.onUserSelected(user.profile),
                                  ),
                                ),
                                const SizedBox(height: 6),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DrawerUser {
  const _DrawerUser({
    required this.profile,
    this.isSelf = false,
    required this.trackingPaused,
    required this.missingPermissions,
    required this.batterySavingEnabled,
    required this.batteryLevel,
  });

  final UserProfile profile;
  final bool isSelf;
  final bool trackingPaused;
  final bool missingPermissions;
  final bool batterySavingEnabled;
  final int? batteryLevel;

  List<_UserStatus> get statuses {
    final result = <_UserStatus>[];
    if (trackingPaused) {
      result.add(_UserStatus('Location tracking paused', Icons.pause_circle));
    }
    if (missingPermissions) {
      result.add(_UserStatus('Missing permissions', Icons.block));
    }
    if (batterySavingEnabled) {
      result.add(_UserStatus('Battery saving enabled', Icons.battery_saver));
    }
    if (batteryLevel != null) {
      result.add(_UserStatus('$batteryLevel% battery', Icons.battery_full));
    }
    return result;
  }
}

class _UserStatus {
  const _UserStatus(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.user,
    required this.isSelected,
    required this.onSelect,
  });

  final _DrawerUser user;
  final bool isSelected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final statuses = user.statuses;
    final hasLocation = user.profile.lastLocation != null;
    final allClear = statuses.isEmpty;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Material(
      color: isSelected
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
          : Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: hasLocation ? onSelect : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundImage: user.profile.avatarUrl.isNotEmpty
                    ? NetworkImage(user.profile.avatarUrl)
                    : null,
                child: user.profile.avatarUrl.isEmpty
                    ? Text(user.profile.name.characters.first.toUpperCase())
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            user.isSelf
                                ? '${user.profile.name} (you)'
                                : user.profile.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        if (allClear) ...[
                          const SizedBox(width: 6),
                          _InlineClearBadge(color: primaryColor),
                        ],
                        if (hasLocation)
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (hasLocation)
                      LocationStreetLabel(
                        location: user.profile.lastLocation!,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 2,
                        placeholder: 'Looking up street...',
                      )
                    else
                      Text(
                        'No recent location',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (!allClear) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: statuses
                            .map(
                              (status) => _StatusChip(
                                label: status.label,
                                icon: status.icon,
                                color: _colorForStatus(context, status),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _colorForStatus(BuildContext context, _UserStatus status) {
    switch (status.icon) {
      case Icons.pause_circle:
        return Colors.amber.shade700;
      case Icons.block:
        return Colors.redAccent;
      case Icons.battery_saver:
        return Colors.teal;
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }
}

class _InlineClearBadge extends StatelessWidget {
  const _InlineClearBadge({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            'All clear',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
