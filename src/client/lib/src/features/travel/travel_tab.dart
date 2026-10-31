import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/periods.dart';
import '../../data/models/leaderboard_entry.dart';
import '../../data/models/user_model.dart';
import '../../data/network/leaderboard_service.dart';
import '../tracking/widgets/location_history_screen.dart';
import '../tracking/widgets/user_avatar.dart';
import '../../core/tokens.dart';
import '../../core/palette.dart';

/// The travel leaderboard: who went furthest this week, this month or over
/// a picked range, with each person's moving time and speeds.
class TravelTab extends StatefulWidget {
  const TravelTab({
    super.key,
    required this.isActive,
    required this.selfId,
    required this.baseUrl,
    required this.getAccessToken,
    @visibleForTesting this.service,
  });

  /// The tab sits in an IndexedStack: it loads when first shown and
  /// refreshes each time it's shown again.
  final bool isActive;
  final String selfId;
  final String baseUrl;
  final String? Function() getAccessToken;
  final LeaderboardService? service;

  @override
  State<TravelTab> createState() => _TravelTabState();
}

class _TravelTabState extends State<TravelTab> {
  // Gold, silver, bronze for the podium.
  static const _medals = AppPalette.medals;

  late final LeaderboardService _service;
  Period _period = Period.containing(PeriodKind.week, DateTime.now());
  List<LeaderboardEntry>? _entries;
  bool _loading = false;
  bool _failed = false;
  // Answers to superseded requests (a quick tap through weeks) must not land.
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? LeaderboardService(baseUrl: widget.baseUrl);
    if (widget.isActive) _load();
  }

  @override
  void didUpdateWidget(covariant TravelTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _load();
  }

  Future<void> _load([Period? next]) async {
    final token = widget.getAccessToken();
    final mine = ++_request;
    setState(() {
      _period = next ?? _period;
      _loading = true;
      _failed = false;
    });
    if (token == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    try {
      final entries = await _service.fetch(
        token,
        from: _period.from,
        to: _period.to,
      );
      if (!mounted || mine != _request) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || mine != _request) return;
      setState(() {
        _entries = null;
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 5),
      lastDate: today,
      initialDateRange: _period.kind == PeriodKind.custom
          ? DateTimeRange(
              start: _period.from,
              end: _period.lastDay.isAfter(today) ? today : _period.lastDay,
            )
          : null,
      helpText: 'Pick the days to rank',
      saveText: 'Show',
    );
    if (picked == null || !mounted) return;
    final period = Period.custom(picked.start, picked.end);
    if (period.days > Period.maxDays) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick at most ${Period.maxDays} days.')),
      );
      return;
    }
    _load(period);
  }

  void _setKind(PeriodKind kind) {
    if (kind == _period.kind) return;
    if (kind == PeriodKind.custom) {
      _pickRange();
      return;
    }
    _load(Period.containing(kind, DateTime.now()));
  }

  /// A ranked person's own trips: the same history screen the map drawer opens.
  void _openHistory(LeaderboardEntry entry) {
    final accessToken = widget.getAccessToken();
    if (accessToken == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocationHistoryScreen(
          user: UserProfile(id: entry.userId, name: entry.name),
          baseUrl: widget.baseUrl,
          accessToken: accessToken,
          canDelete: entry.userId == widget.selfId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    final trips = entries?.fold<int>(0, (sum, e) => sum + e.tripCount) ?? 0;
    final distance =
        entries?.fold<double>(0, (sum, e) => sum + e.distanceMeters) ?? 0;
    final leader = entries == null || entries.isEmpty
        ? 0.0
        : entries.first.distanceMeters;

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text(
              'Travel',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<PeriodKind>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: PeriodKind.week, label: Text('Week')),
                ButtonSegment(value: PeriodKind.month, label: Text('Month')),
                ButtonSegment(
                  value: PeriodKind.custom,
                  label: Text('Custom'),
                  icon: Icon(Icons.date_range_rounded, size: 18),
                ),
              ],
              selected: {_period.kind},
              onSelectionChanged: (kinds) => _setKind(kinds.single),
            ),
            const SizedBox(height: 12),
            _PeriodCard(
              period: _period,
              loading: _loading,
              onShift: (delta) => _load(_period.shift(delta)),
              onEdit: _period.kind == PeriodKind.custom ? _pickRange : null,
            ),
            const SizedBox(height: 20),
            if (_failed)
              _Message(
                icon: Icons.cloud_off_rounded,
                text: 'Couldn\'t load the leaderboard.',
                action: TextButton(
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
              )
            else if (entries == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (trips == 0)
              const _Message(
                icon: Icons.directions_car_rounded,
                text: 'Nobody travelled in this period.',
              )
            else
              AnimatedOpacity(
                opacity: _loading ? 0.6 : 1,
                duration: AppMotion.of(context, AppMotion.medium),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                      child: Text(
                        '${formatDistance(distance)} together · '
                        '$trips ${trips == 1 ? 'trip' : 'trips'}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    for (final entry in entries) ...[
                      _EntryCard(
                        // Each card follows its person when the order changes.
                        key: ValueKey(entry.userId),
                        entry: entry,
                        isSelf: entry.userId == widget.selfId,
                        share: leader > 0 ? entry.distanceMeters / leader : 0,
                        medal: entry.rank <= 3 && entry.tripCount > 0
                            ? _medals[entry.rank - 1]
                            : null,
                        onTap: () => _openHistory(entry),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PeriodCard extends StatelessWidget {
  const _PeriodCard({
    required this.period,
    required this.loading,
    required this.onShift,
    required this.onEdit,
  });

  final Period period;
  final bool loading;
  final ValueChanged<int> onShift;

  /// Custom ranges reopen the picker from their label.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noun = period.kind == PeriodKind.custom ? 'range' : period.kind.name;
    final label = Text(
      formatPeriod(period),
      textAlign: TextAlign.center,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            height: 3,
            child: loading ? const LinearProgressIndicator() : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous $noun',
                  onPressed: () => onShift(-1),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: onEdit == null
                      ? label
                      : TextButton.icon(
                          onPressed: onEdit,
                          icon: const Icon(
                            Icons.edit_calendar_rounded,
                            size: 18,
                          ),
                          label: label,
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurface,
                          ),
                        ),
                ),
                IconButton(
                  tooltip: 'Next $noun',
                  onPressed: period.isCurrentOrLater()
                      ? null
                      : () => onShift(1),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.entry,
    required this.isSelf,
    required this.share,
    required this.medal,
    required this.onTap,
  });

  final LeaderboardEntry entry;
  final bool isSelf;

  /// The entry's distance as a fraction of the leader's.
  final double share;
  final Color? medal;

  /// Opens this person's trips.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: AppShape.lg,
        side: isSelf
            ? BorderSide(
                color: scheme.primary.withValues(alpha: 0.7),
                width: 1.5,
              )
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: medal,
                    ),
                    child: Text(
                      '${entry.rank}',
                      semanticsLabel: 'Rank ${entry.rank}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: medal != null
                            ? AppPalette.onMedal
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  UserAvatar(userId: entry.userId, name: entry.name, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isSelf ? '${entry.name} (you)' : entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          entry.tripCount > 0
                              ? '${entry.tripCount} '
                                    '${entry.tripCount == 1 ? 'trip' : 'trips'} · '
                                    '${formatTripDuration(entry.duration)}'
                              : 'No trips',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatDistance(entry.distanceMeters),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: AppShape.full,
                child: LinearProgressIndicator(
                  value: share.clamp(0, 1),
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              if (entry.tripCount > 0) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _StatChip(
                      icon: Icons.speed_outlined,
                      label: '${entry.avgSpeedKmh.round()} km/h avg',
                    ),
                    _StatChip(
                      icon: Icons.speed_rounded,
                      label: '${entry.topSpeedKmh.round()} km/h top',
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppShape.full,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(label, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(icon, size: 32, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
