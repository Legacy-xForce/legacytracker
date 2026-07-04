import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/models/location_model.dart';
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
  String? _detailUserId;

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

  void _openDetail(UserProfile profile) {
    widget.onUserSelected(profile);
    setState(() => _detailUserId = profile.id);
    if (_sheetController.size < _expandedSize) {
      _sheetController.animateTo(
        _expandedSize,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _closeDetail() {
    setState(() => _detailUserId = null);
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
        isCharging: widget.selfProfile.isCharging,
      ),
      ...widget.peers.map(
        (peer) => _DrawerUser(
          profile: peer,
          trackingPaused: peer.locationTrackingPaused,
          missingPermissions: peer.missingPermissions,
          batterySavingEnabled: peer.batterySavingEnabled,
          batteryLevel: peer.batteryLevel,
          isCharging: peer.isCharging,
        ),
      ),
    ];

    _DrawerUser? detailUser;
    if (_detailUserId != null) {
      for (final user in users) {
        if (user.profile.id == _detailUserId) {
          detailUser = user;
          break;
        }
      }
    }

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
                        child: detailUser != null
                            ? _UserDetailPane(
                                user: detailUser,
                                scrollController: scrollController,
                                bottomInset: bottomInset,
                                onBack: _closeDetail,
                              )
                            : ListView(
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
                                          onSelect: () => _openDetail(
                                            user.profile,
                                          ),
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
    required this.isCharging,
  });

  final UserProfile profile;
  final bool isSelf;
  final bool trackingPaused;
  final bool missingPermissions;
  final bool batterySavingEnabled;
  final int? batteryLevel;
  final bool? isCharging;

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
      case Icons.battery_charging_full:
        return Colors.green.shade600;
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

String _formatDuration(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
  }
  return '${duration.inSeconds}s';
}

/// Inline detail view shown in place of the user list once a row is tapped.
/// Speed/battery/duration come from live data; the trip-stats and location
/// history sections are placeholders (flagged "Coming soon") until the
/// backend exposes real trip data.
class _UserDetailPane extends StatelessWidget {
  const _UserDetailPane({
    required this.user,
    required this.scrollController,
    required this.bottomInset,
    required this.onBack,
  });

  final _DrawerUser user;
  final ScrollController scrollController;
  final double bottomInset;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = user.profile;
    final loc = profile.lastLocation;
    final mock = _MockTripStats.forUser(profile.id);

    return ListView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(16, 2, 16, 16 + bottomInset),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to list',
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            CircleAvatar(
              radius: 22,
              backgroundImage: profile.avatarUrl.isNotEmpty
                  ? NetworkImage(profile.avatarUrl)
                  : null,
              child: profile.avatarUrl.isEmpty
                  ? Text(profile.name.characters.first.toUpperCase())
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.isSelf ? '${profile.name} (you)' : profile.name,
                    style: theme.textTheme.titleMedium,
                  ),
                  if (loc != null)
                    LocationStreetLabel(
                      location: loc,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      placeholder: 'Looking up street...',
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (loc != null)
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.speed_rounded,
                  label: 'Speed',
                  value: '${(loc.speed * 3.6).round()} km/h',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatCard(
                  icon: profile.isCharging == true
                      ? Icons.battery_charging_full_rounded
                      : Icons.battery_std_rounded,
                  label: 'Battery',
                  value: profile.batteryLevel == null
                      ? 'Unknown'
                      : '${profile.batteryLevel}%'
                            '${profile.isCharging == true ? ' (charging)' : ''}',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatCard(
                  icon: Icons.timer_outlined,
                  label: 'Here for',
                  value: _formatDuration(
                    DateTime.now().difference(loc.timestamp),
                  ),
                ),
              ),
            ],
          )
        else
          Text('No recent location', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 24),
        const _SectionHeader(title: 'Trip stats', showSoonBadge: true),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.route_outlined,
                label: 'Drives today',
                value: '${mock.driveCount}',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                icon: Icons.trending_up_rounded,
                label: 'Top speed',
                value: '${mock.topSpeedKmh} km/h',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                icon: Icons.speed_outlined,
                label: 'Avg speed',
                value: '${mock.avgSpeedKmh} km/h',
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const _SectionHeader(title: 'Location history', showSoonBadge: true),
        const SizedBox(height: 10),
        ...mock.mockHistory(loc).map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _HistoryTile(point: entry.point, minutesAgo: entry.minutesAgo),
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.showSoonBadge = false});

  final String title;
  final bool showSoonBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (showSoonBadge) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.amber.shade700.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Colors.amber.shade700.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              'Coming soon',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.amber.shade800,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.point, required this.minutesAgo});

  final LocationPoint? point;
  final int minutesAgo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.3,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.location_on_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: point == null
                ? Text(
                    'Stop $minutesAgo min ago',
                    style: theme.textTheme.bodySmall,
                  )
                : LocationStreetLabel(
                    location: point!,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    placeholder: 'Looking up street...',
                  ),
          ),
          const SizedBox(width: 8),
          Text(
            '${minutesAgo}m ago',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _MockHistoryEntry {
  const _MockHistoryEntry({required this.point, required this.minutesAgo});

  final LocationPoint? point;
  final int minutesAgo;
}

/// Deterministic per-user placeholder numbers so the same person doesn't
/// reshuffle their stats on every rebuild, while still varying across users.
class _MockTripStats {
  const _MockTripStats({
    required this.driveCount,
    required this.topSpeedKmh,
    required this.avgSpeedKmh,
    required this.seed,
  });

  final int driveCount;
  final int topSpeedKmh;
  final int avgSpeedKmh;
  final int seed;

  static _MockTripStats forUser(String id) {
    final random = math.Random(id.hashCode);
    return _MockTripStats(
      driveCount: 2 + random.nextInt(9),
      topSpeedKmh: 45 + random.nextInt(70),
      avgSpeedKmh: 18 + random.nextInt(35),
      seed: id.hashCode,
    );
  }

  /// Nearby placeholder stops so the street lookup still resolves to a
  /// plausible real address near the user's current position.
  List<_MockHistoryEntry> mockHistory(LocationPoint? near) {
    final random = math.Random(seed);
    return List.generate(3, (i) {
      if (near == null) {
        return _MockHistoryEntry(point: null, minutesAgo: (i + 1) * 22);
      }
      double jitter() => (random.nextDouble() - 0.5) * 0.01;
      return _MockHistoryEntry(
        point: LocationPoint(
          latitude: near.latitude + jitter(),
          longitude: near.longitude + jitter(),
          speed: (10 + random.nextInt(20)).toDouble(),
          timestamp: near.timestamp.subtract(Duration(minutes: (i + 1) * 22)),
        ),
        minutesAgo: (i + 1) * 22,
      );
    });
  }
}
