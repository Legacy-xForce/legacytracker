import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/formatters.dart';
import '../../../data/models/location_session.dart';
import '../../../data/models/user_model.dart';
import '../../../data/network/history_service.dart';
import '../../../data/network/sharing_service.dart';
import '../../auth/auth_provider.dart';
import '../local_avatar_store.dart';
import '../sharing_provider.dart';
import '../tracking_controller.dart';
import 'location_history_screen.dart';
import 'tracking_location_street_label.dart';
import 'user_avatar.dart';

/// The people sheet over the map: a list of everyone sharing, and a detail
/// pane for whoever is selected. Collapsed it still shows its header, so it
/// is obvious there's something to pull up.
class TrackingUsersDrawer extends StatefulWidget {
  const TrackingUsersDrawer({
    super.key,
    required this.selfProfile,
    required this.peers,
    required this.selfTrackingPaused,
    required this.selfMissingPermissions,
    required this.selfBatterySavingEnabled,
    required this.selectedUserId,
    this.selectionTick = 0,
    required this.onUserSelected,
    this.onExtentChanged,
  });

  final UserProfile selfProfile;
  final List<UserProfile> peers;
  final bool selfTrackingPaused;
  final bool selfMissingPermissions;
  final bool selfBatterySavingEnabled;
  final String? selectedUserId;

  /// Bumped on every selection, including re-selecting the same person.
  final int selectionTick;
  final ValueChanged<UserProfile> onUserSelected;

  /// The fraction of the map's height the sheet currently covers, so the map
  /// can keep a focused marker in the part that's still visible.
  final ValueChanged<double>? onExtentChanged;

  /// Height fraction of the fully open sheet.
  static const double expandedSize = 0.6;

  @override
  State<TrackingUsersDrawer> createState() => _TrackingUsersDrawerState();
}

class _TrackingUsersDrawerState extends State<TrackingUsersDrawer> {
  static const double _expandedSize = TrackingUsersDrawer.expandedSize;

  /// Drag handle plus the "People" header: what stays visible collapsed.
  static const double _headerHeight = 68;

  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  // Recomputed from the available height on every layout.
  double _collapsedSize = 0.1;
  double _sheetSize = 0.1;
  String? _detailUserId;

  @override
  void initState() {
    super.initState();
    _sheetController.addListener(_handleSheetChanged);
    _detailUserId = widget.selectedUserId;
  }

  @override
  void didUpdateWidget(covariant TrackingUsersDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A selection made outside the drawer (tapping a marker or a cluster face
    // on the map) should open the same detail pane a drawer row tap would,
    // instead of leaving the drawer showing just the list.
    if (widget.selectedUserId != null &&
        (widget.selectedUserId != oldWidget.selectedUserId ||
            widget.selectionTick != oldWidget.selectionTick)) {
      setState(() => _detailUserId = widget.selectedUserId);
      _expand();
    }
  }

  @override
  void dispose() {
    _sheetController.removeListener(_handleSheetChanged);
    _sheetController.dispose();
    super.dispose();
  }

  void _handleSheetChanged() {
    final size = _sheetController.size;
    widget.onExtentChanged?.call(size);
    if ((size - _sheetSize).abs() > 0.001 && mounted) {
      setState(() => _sheetSize = size);
    }
  }

  bool get _isCollapsed => _sheetSize <= _collapsedSize + 0.01;

  void _expand() {
    if (_sheetController.isAttached && _sheetController.size < _expandedSize) {
      _animateTo(_expandedSize);
    }
  }

  void _animateTo(double size) {
    _sheetController.animateTo(
      size,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggle() => _animateTo(_isCollapsed ? _expandedSize : _collapsedSize);

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
    final snapZone = (_expandedSize - _collapsedSize) * 0.15;
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
      _animateTo(target);
    }
  }

  void _openDetail(UserProfile profile) {
    widget.onUserSelected(profile);
    setState(() => _detailUserId = profile.id);
    _expand();
  }

  void _closeDetail() {
    setState(() => _detailUserId = null);
  }

  @override
  Widget build(BuildContext context) {
    final selfAvatarBytes = context.watch<LocalAvatarStore?>()?.bytes;
    final users = [
      _DrawerUser(
        profile: widget.selfProfile,
        isSelf: true,
        avatarBytes: selfAvatarBytes,
        trackingPaused: widget.selfTrackingPaused,
        missingPermissions: widget.selfMissingPermissions,
        batterySavingEnabled: widget.selfBatterySavingEnabled,
      ),
      ...widget.peers
          .where((peer) => peer.lastLocation != null || !peer.sharesWithMe)
          .map(
            (peer) => _DrawerUser(
              profile: peer,
              trackingPaused: peer.locationTrackingPaused,
              missingPermissions: peer.missingPermissions,
              batterySavingEnabled: peer.batterySavingEnabled,
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

    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return LayoutBuilder(
      builder: (context, constraints) {
        _collapsedSize = (_headerHeight / constraints.maxHeight).clamp(
          0.05,
          0.3,
        );
        if (!_sheetController.isAttached) _sheetSize = _collapsedSize;

        return Align(
          alignment: Alignment.bottomCenter,
          child: DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: _collapsedSize,
            minChildSize: _collapsedSize,
            maxChildSize: _expandedSize,
            expand: false,
            builder: (context, scrollController) {
              final contentOpacity =
                  ((_sheetSize - _collapsedSize) /
                          ((_expandedSize - _collapsedSize) * 0.15))
                      .clamp(0.0, 1.0);
              return Material(
                color: theme.colorScheme.surfaceContainerLow,
                elevation: 16,
                shadowColor: Colors.black,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggle,
                      onVerticalDragUpdate: (details) {
                        _dragSheet(
                          details.primaryDelta ?? 0,
                          constraints.maxHeight,
                        );
                      },
                      onVerticalDragEnd: _settleSheet,
                      child: _SheetHeader(
                        height: _headerHeight,
                        users: users,
                        showingDetail: detailUser != null && !_isCollapsed,
                        onBack: _closeDetail,
                      ),
                    ),
                    Expanded(
                      child: IgnorePointer(
                        ignoring: _isCollapsed,
                        child: Opacity(
                          opacity: contentOpacity,
                          child: detailUser != null
                              ? _UserDetailPane(
                                  key: ValueKey(detailUser.profile.id),
                                  user: detailUser,
                                  scrollController: scrollController,
                                  bottomInset: bottomInset,
                                )
                              : ListView.separated(
                                  controller: scrollController,
                                  padding: EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    16 + bottomInset,
                                  ),
                                  itemCount: users.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(height: 4),
                                  itemBuilder: (context, index) => _UserRow(
                                    user: users[index],
                                    isSelected:
                                        widget.selectedUserId ==
                                        users[index].profile.id,
                                    onSelect: () =>
                                        _openDetail(users[index].profile),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.height,
    required this.users,
    required this.showingDetail,
    required this.onBack,
  });

  final double height;
  final List<_DrawerUser> users;
  final bool showingDetail;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: Row(
                children: [
                  if (showingDetail) ...[
                    IconButton(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back_rounded),
                      tooltip: 'All people',
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size.square(36),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('All people', style: theme.textTheme.titleMedium),
                  ] else ...[
                    Text(
                      'People',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${users.length}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (!showingDetail) _AvatarStack(users: users),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A few overlapping faces in the header — a glance at who's sharing.
class _AvatarStack extends StatelessWidget {
  const _AvatarStack({required this.users});

  final List<_DrawerUser> users;

  static const _size = 28.0;
  static const _step = 20.0;
  static const _max = 4;

  @override
  Widget build(BuildContext context) {
    final shown = users.take(_max).toList();
    final ring = Theme.of(context).colorScheme.surfaceContainerLow;
    return SizedBox(
      width: _size + (shown.length - 1) * _step,
      height: _size,
      child: Stack(
        children: [
          for (var i = shown.length - 1; i >= 0; i--)
            Positioned(
              left: i * _step,
              child: UserAvatar(
                userId: shown[i].profile.id,
                name: shown[i].profile.name,
                avatarUrl: shown[i].profile.avatarUrl,
                imageBytes: shown[i].avatarBytes,
                size: _size,
                ringColor: ring,
                ringWidth: 2,
                dimmed: shown[i].isStale,
              ),
            ),
        ],
      ),
    );
  }
}

class _DrawerUser {
  const _DrawerUser({
    required this.profile,
    this.isSelf = false,
    this.avatarBytes,
    required this.trackingPaused,
    required this.missingPermissions,
    required this.batterySavingEnabled,
  });

  final UserProfile profile;
  final bool isSelf;
  final Uint8List? avatarBytes;
  final bool trackingPaused;
  final bool missingPermissions;
  final bool batterySavingEnabled;

  String get displayName => isSelf ? '${profile.name} (you)' : profile.name;

  bool get isStale => !isSelf && profile.isStale;

  List<_UserStatus> get statuses {
    final result = <_UserStatus>[];
    if (!profile.sharesWithMe) {
      result.add(
        _UserStatus(
          'Not sharing with you',
          Icons.visibility_off_outlined,
          Colors.blueGrey,
        ),
      );
    }
    if (trackingPaused) {
      result.add(
        _UserStatus('Sharing paused', Icons.pause_circle, Colors.amber),
      );
    }
    if (missingPermissions) {
      result.add(
        _UserStatus('Missing permissions', Icons.block, Colors.redAccent),
      );
    }
    if (batterySavingEnabled) {
      result.add(
        _UserStatus('Battery saver', Icons.battery_saver, Colors.tealAccent),
      );
    }
    return result;
  }

  /// When this user's position last reached the server, as "Updated 5 min
  /// ago". Null when there is no position to date.
  String? updatedAgo(DateTime now) {
    final location = profile.lastLocation;
    if (!profile.sharesWithMe || location == null) return null;
    final sent = profile.lastSeenAt ?? location.timestamp;
    return 'Updated ${formatUpdatedAgo(now.difference(sent))}';
  }

  /// Where this user is in time: how long they've been here, that they're
  /// on the move, or — if their phone went quiet — when we last heard.
  _Presence presence(DateTime now) {
    if (!profile.sharesWithMe) {
      return const _Presence(
        Icons.visibility_off_outlined,
        'Location',
        'Hidden',
        'Location hidden',
      );
    }
    final location = profile.lastLocation;
    if (location == null) {
      return const _Presence(
        Icons.location_off_outlined,
        'Location',
        'None yet',
        'No location yet',
      );
    }
    if (isStale) {
      final seen = profile.lastSeenAt;
      final ago = seen == null
          ? 'a while ago'
          : '${formatElapsed(now.difference(seen))} ago';
      return _Presence(
        Icons.history_rounded,
        'Last seen',
        seen == null ? '—' : ago,
        'Last seen $ago',
      );
    }
    if (profile.isTravelling) {
      return const _Presence(
        Icons.near_me_rounded,
        'Status',
        'Moving',
        'Moving',
      );
    }
    final here = formatElapsed(
      now.difference(profile.hereSince ?? location.timestamp),
    );
    return _Presence(Icons.timer_outlined, 'Here for', here, 'Here for $here');
  }
}

class _Presence {
  const _Presence(this.icon, this.label, this.value, this.sentence);

  final IconData icon;

  /// Stat-card label and value: "Here for" / "2h 45m".
  final String label;
  final String value;

  /// The same as one line for the people list: "Here for 2h 45m".
  final String sentence;
}

class _UserStatus {
  const _UserStatus(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

/// Rebuilds every second, for live "Here for" counters.
class _Ticking extends StatefulWidget {
  const _Ticking({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statuses = user.statuses;
    final location = user.profile.lastLocation;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Material(
      color: isSelected
          ? scheme.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: location != null || !user.profile.sharesWithMe ? onSelect : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          child: Row(
            children: [
              _PresenceAvatar(user: user, size: 46),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (location != null)
                      LocationStreetLabel(
                        location: location,
                        style: muted,
                        maxLines: 1,
                        placeholder: 'Looking up street…',
                      ),
                    _Ticking(
                      builder: (context) {
                        final presence = user.presence(DateTime.now());
                        return Text(
                          presence.sentence,
                          style: muted?.copyWith(
                            color: user.profile.isTravelling && !user.isStale
                                ? scheme.primary
                                : null,
                            fontWeight: user.profile.isTravelling
                                ? FontWeight.w600
                                : null,
                          ),
                        );
                      },
                    ),
                    if (statuses.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final status in statuses)
                            _StatusChip(status: status),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _BatteryPill(
                level: user.profile.batteryLevel,
                charging: user.profile.isCharging ?? false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Avatar with a small dot: green while sharing, grey when the phone has
/// gone quiet, amber when sharing is paused.
class _PresenceAvatar extends StatelessWidget {
  const _PresenceAvatar({required this.user, required this.size});

  final _DrawerUser user;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dotColor = user.trackingPaused
        ? Colors.amber
        : user.isStale
        ? Colors.grey.shade500
        : const Color(0xFF34C759);
    final dot = size * 0.28;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          UserAvatar(
            userId: user.profile.id,
            name: user.profile.name,
            avatarUrl: user.profile.avatarUrl,
            imageBytes: user.avatarBytes,
            size: size,
            dimmed: user.isStale,
          ),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  width: 2.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BatteryPill extends StatelessWidget {
  const _BatteryPill({required this.level, required this.charging});

  final int? level;
  final bool charging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final level = this.level;
    if (level == null) return const SizedBox.shrink();
    final low = level <= 20 && !charging;
    final color = charging
        ? const Color(0xFF34C759)
        : low
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          charging ? Icons.bolt_rounded : _batteryIcon(level),
          size: 16,
          color: color,
        ),
        const SizedBox(width: 2),
        Text(
          '$level%',
          style: theme.textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

IconData _batteryIcon(int level) {
  if (level >= 90) return Icons.battery_full_rounded;
  if (level >= 60) return Icons.battery_5_bar_rounded;
  if (level >= 40) return Icons.battery_3_bar_rounded;
  if (level >= 20) return Icons.battery_2_bar_rounded;
  return Icons.battery_alert_rounded;
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final _UserStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 13, color: status.color),
          const SizedBox(width: 4),
          Text(
            status.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: status.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline detail view shown in place of the user list once a row is tapped.
/// Speed/battery/"here for" come from live data; trip stats are derived from
/// today's location-history sessions. Trip history opens the calendar.
class _UserDetailPane extends StatefulWidget {
  const _UserDetailPane({
    super.key,
    required this.user,
    required this.scrollController,
    required this.bottomInset,
  });

  final _DrawerUser user;
  final ScrollController scrollController;
  final double bottomInset;

  @override
  State<_UserDetailPane> createState() => _UserDetailPaneState();
}

class _UserDetailPaneState extends State<_UserDetailPane> {
  late final Future<List<LocationSession>> _todaySessions;

  @override
  void initState() {
    super.initState();
    _todaySessions = _loadTodaySessions();
  }

  Future<List<LocationSession>> _loadTodaySessions() {
    final accessToken = context.read<AuthProvider>().tokens?.accessToken;
    if (accessToken == null || !widget.user.profile.sharesWithMe) {
      return Future.value(const []);
    }

    final baseUrl = context.read<TrackingController>().baseUrl;
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);
    final to = from.add(const Duration(days: 1));
    return HistoryService(baseUrl: baseUrl).fetchHistory(
      accessToken,
      userId: widget.user.profile.id,
      from: from,
      to: to,
      includePoints: false,
    );
  }

  void _openHistory() {
    final baseUrl = context.read<TrackingController>().baseUrl;
    final accessToken = context.read<AuthProvider>().tokens?.accessToken;
    if (accessToken == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocationHistoryScreen(
          user: widget.user.profile,
          baseUrl: baseUrl,
          accessToken: accessToken,
        ),
      ),
    );
  }

  Future<void> _setSharing(SharingProvider sharing, bool enabled) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await sharing.setSharing(widget.user.profile.id, enabled);
    } on SharingException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = widget.user;
    final profile = user.profile;
    final loc = profile.lastLocation;
    final sharing = user.isSelf ? null : context.watch<SharingProvider?>();

    return ListView(
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + widget.bottomInset),
      children: [
        Row(
          children: [
            _PresenceAvatar(user: user, size: 52),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.displayName,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (loc != null)
                    LocationStreetLabel(
                      location: loc,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      placeholder: 'Looking up street…',
                    ),
                  _Ticking(
                    builder: (context) {
                      final updated = user.updatedAgo(DateTime.now());
                      if (updated == null) return const SizedBox.shrink();
                      return Text(
                        updated,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        if (user.statuses.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final status in user.statuses) _StatusChip(status: status),
            ],
          ),
        ],
        if (sharing != null) ...[
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.share_location_rounded),
            title: Text('Share my location with ${profile.name}'),
            subtitle: Text(
              sharing.isSharingWith(profile.id)
                  ? '${profile.name} can see you on the map'
                  : "${profile.name} can't see you on the map",
            ),
            value: sharing.isSharingWith(profile.id),
            onChanged: (enabled) => _setSharing(sharing, enabled),
          ),
        ],
        const SizedBox(height: 18),
        if (!profile.sharesWithMe)
          Text(
            "${profile.name} isn't sharing their location with you.",
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else if (loc != null)
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
                  label: profile.isCharging == true ? 'Charging' : 'Battery',
                  value: profile.batteryLevel == null
                      ? '—'
                      : '${profile.batteryLevel}%',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Ticking(
                  builder: (context) {
                    final presence = user.presence(DateTime.now());
                    return _StatCard(
                      icon: presence.icon,
                      label: presence.label,
                      value: presence.value,
                    );
                  },
                ),
              ),
            ],
          )
        else
          Text('No recent location', style: theme.textTheme.bodyMedium),
        if (profile.sharesWithMe) ...[
          const SizedBox(height: 22),
          const _SectionHeader(title: 'Today'),
          const SizedBox(height: 10),
          FutureBuilder<List<LocationSession>>(
            future: _todaySessions,
            builder: (context, snapshot) {
              final loading = snapshot.connectionState != ConnectionState.done;
              final summary = _TripStatsSummary.fromSessions(
                snapshot.data ?? const [],
              );
              return Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      icon: Icons.route_outlined,
                      label: summary.driveCount == 1 ? 'Trip' : 'Trips',
                      value: loading ? '…' : '${summary.driveCount}',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.trending_up_rounded,
                      label: 'Top speed',
                      value: loading
                          ? '…'
                          : '${summary.topSpeedKmh.round()} km/h',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.speed_outlined,
                      label: 'Avg speed',
                      value: loading
                          ? '…'
                          : '${summary.avgSpeedKmh.round()} km/h',
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 22),
          FilledButton.tonalIcon(
            onPressed: _openHistory,
            icon: const Icon(Icons.calendar_month_rounded),
            label: const Text('Trip history'),
          ),
        ],
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
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

/// Aggregate "trip" stats derived from a set of location-history sessions
/// (one call to `/api/v1/history` for the day already returns these).
class _TripStatsSummary {
  const _TripStatsSummary({
    required this.driveCount,
    required this.topSpeedKmh,
    required this.avgSpeedKmh,
  });

  final int driveCount;
  final double topSpeedKmh;
  final double avgSpeedKmh;

  static _TripStatsSummary fromSessions(List<LocationSession> sessions) {
    if (sessions.isEmpty) {
      return const _TripStatsSummary(
        driveCount: 0,
        topSpeedKmh: 0,
        avgSpeedKmh: 0,
      );
    }

    var topSpeedKmh = 0.0;
    var weightedAvgSpeedKmh = 0.0;
    var totalDurationSeconds = 0.0;
    for (final session in sessions) {
      topSpeedKmh = math.max(topSpeedKmh, session.topSpeedKmh);
      weightedAvgSpeedKmh += session.avgSpeedKmh * session.durationSeconds;
      totalDurationSeconds += session.durationSeconds;
    }

    // Duration-weighted average of each session's own average speed (a mean
    // of its recorded point speeds), so long drives aren't diluted by short
    // ones. Unlike distance/time, this can never exceed topSpeedKmh, since
    // it's a weighted average of values that are each already <= it.
    final avgSpeedKmh = totalDurationSeconds > 0
        ? weightedAvgSpeedKmh / totalDurationSeconds
        : 0.0;

    return _TripStatsSummary(
      driveCount: sessions.length,
      topSpeedKmh: topSpeedKmh,
      avgSpeedKmh: avgSpeedKmh,
    );
  }
}
