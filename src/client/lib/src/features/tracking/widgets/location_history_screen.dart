import 'package:flutter/material.dart';

import '../../../core/formatters.dart';
import '../../../data/models/location_session.dart';
import '../../../data/models/user_model.dart';
import '../../../data/network/history_service.dart';
import 'session_replay_screen.dart';
import 'tracking_location_street_label.dart';

/// A user's trips: a month calendar marking the days with trips first, then
/// the selected day's trips, each opening a replay.
class LocationHistoryScreen extends StatefulWidget {
  const LocationHistoryScreen({
    super.key,
    required this.user,
    required this.baseUrl,
    required this.accessToken,
    this.canDelete = false,
    @visibleForTesting this.historyService,
  });

  final UserProfile user;
  final String baseUrl;
  final String accessToken;

  /// Only your own trips can be deleted.
  final bool canDelete;
  final HistoryService? historyService;

  @override
  State<LocationHistoryScreen> createState() => _LocationHistoryScreenState();
}

class _LocationHistoryScreenState extends State<LocationHistoryScreen> {
  static const _monthsBack = 12;

  late final HistoryService _historyService;
  late final DateTime _currentMonth;
  late DateTime _month;
  DateTime? _selectedDay;

  // Month summaries (no points) drive the calendar; a day's full sessions
  // (with points, for street names and replay) load when it's picked.
  final Map<DateTime, Future<Map<int, _DaySummary>>> _months = {};
  final Map<DateTime, Future<List<LocationSession>>> _days = {};

  @override
  void initState() {
    super.initState();
    _historyService =
        widget.historyService ?? HistoryService(baseUrl: widget.baseUrl);
    final now = DateTime.now();
    _currentMonth = DateTime(now.year, now.month);
    _month = _currentMonth;
  }

  DateTime get _oldestMonth =>
      DateTime(_currentMonth.year, _currentMonth.month - _monthsBack);

  Future<Map<int, _DaySummary>> _summariesFor(DateTime month) {
    return _months.putIfAbsent(month, () async {
      final sessions = await _historyService.fetchHistory(
        widget.accessToken,
        userId: widget.user.id,
        from: month,
        to: DateTime(month.year, month.month + 1),
        includePoints: false,
      );
      final byDay = <int, _DaySummary>{};
      for (final session in sessions) {
        final start = session.startAt.toLocal();
        if (start.year != month.year || start.month != month.month) continue;
        byDay.update(
          start.day,
          (day) => day.add(session),
          ifAbsent: () => _DaySummary.of(session),
        );
      }
      return byDay;
    });
  }

  Future<List<LocationSession>> _sessionsFor(DateTime day) {
    return _days.putIfAbsent(
      day,
      () => _historyService.fetchHistory(
        widget.accessToken,
        userId: widget.user.id,
        from: day,
        to: DateTime(day.year, day.month, day.day + 1),
      ),
    );
  }

  void _showMonth(DateTime month) {
    if (month.isBefore(_oldestMonth) || month.isAfter(_currentMonth)) return;
    setState(() => _month = month);
  }

  void _retryMonth() {
    setState(() => _months.remove(_month));
  }

  bool _deleting = false;

  Future<bool> _confirmDelete(String title, String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Erases [from]..[to] of your own history; on success the cached month and
  /// day are dropped so the calendar and the list reload without it.
  Future<bool> _erase(DateTime from, DateTime to, String done) async {
    if (_deleting) return false;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _deleting = true);
    try {
      await _historyService.deleteHistory(
        widget.accessToken,
        from: from,
        to: to,
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "Couldn't delete. Check your connection and try again.",
          ),
        ),
      );
      if (mounted) setState(() => _deleting = false);
      return false;
    }
    messenger.showSnackBar(SnackBar(content: Text(done)));
    if (!mounted) return true;
    setState(() {
      _deleting = false;
      _months.remove(_month);
      _days.clear();
    });
    return true;
  }

  Future<void> _deleteTrip(LocationSession session) async {
    final confirmed = await _confirmDelete(
      'Delete this trip?',
      'The trip from ${formatClock(session.startAt)} to '
          '${formatClock(session.endAt)} will be erased for good. '
          'This can\'t be undone.',
    );
    if (!confirmed || !mounted) return;
    await _erase(session.startAt, session.endAt, 'Trip deleted');
  }

  Future<void> _deleteDay(DateTime day, int trips) async {
    final confirmed = await _confirmDelete(
      'Delete this day?',
      '${trips == 1 ? 'The trip' : 'All $trips trips'} on '
          '${formatLongDay(day)} will be erased for good. '
          'This can\'t be undone.',
    );
    if (!confirmed || !mounted) return;
    // Up to the day's last millisecond, as the server's range is inclusive.
    final end = DateTime(day.year, day.month, day.day + 1);
    final deleted = await _erase(
      day,
      end.subtract(const Duration(milliseconds: 1)),
      'Day deleted',
    );
    if (deleted && mounted) setState(() => _selectedDay = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Trip history'),
            Text(
              widget.user.name,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: FutureBuilder<Map<int, _DaySummary>>(
        future: _summariesFor(_month),
        builder: (context, snapshot) {
          final loading = snapshot.connectionState != ConnectionState.done;
          final days = snapshot.data ?? const <int, _DaySummary>{};
          final selected = _selectedDay;
          final selectedInMonth =
              selected != null &&
              selected.year == _month.year &&
              selected.month == _month.month;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _CalendarCard(
                month: _month,
                days: days,
                loading: loading,
                selectedDay: selectedInMonth ? selected : null,
                canGoBack: _month.isAfter(_oldestMonth),
                canGoForward: _month.isBefore(_currentMonth),
                onMonthChanged: _showMonth,
                onDaySelected: (day) => setState(() => _selectedDay = day),
              ),
              const SizedBox(height: 20),
              if (snapshot.hasError)
                _Message(
                  icon: Icons.cloud_off_rounded,
                  text: 'Couldn\'t load this month\'s trips.',
                  action: TextButton(
                    onPressed: _retryMonth,
                    child: const Text('Retry'),
                  ),
                )
              else if (loading)
                const SizedBox.shrink()
              else if (selectedInMonth)
                _DayTrips(
                  day: selected,
                  summary: days[selected.day],
                  sessions: _sessionsFor(selected),
                  user: widget.user,
                  onDeleteDay: widget.canDelete && !_deleting
                      ? () => _deleteDay(selected, days[selected.day]!.trips)
                      : null,
                  onDeleteTrip: widget.canDelete && !_deleting
                      ? _deleteTrip
                      : null,
                )
              else
                _MonthOverview(days: days),
            ],
          );
        },
      ),
    );
  }
}

class _DaySummary {
  const _DaySummary({
    required this.trips,
    required this.distanceMeters,
    required this.duration,
  });

  factory _DaySummary.of(LocationSession session) => _DaySummary(
    trips: 1,
    distanceMeters: session.distanceMeters,
    duration: session.duration,
  );

  final int trips;
  final double distanceMeters;
  final Duration duration;

  _DaySummary add(LocationSession session) => _DaySummary(
    trips: trips + 1,
    distanceMeters: distanceMeters + session.distanceMeters,
    duration: duration + session.duration,
  );

  String get description =>
      '$trips ${trips == 1 ? 'trip' : 'trips'} · '
      '${formatDistance(distanceMeters)} · ${formatTripDuration(duration)}';
}

class _CalendarCard extends StatelessWidget {
  const _CalendarCard({
    required this.month,
    required this.days,
    required this.loading,
    required this.selectedDay,
    required this.canGoBack,
    required this.canGoForward,
    required this.onMonthChanged,
    required this.onDaySelected,
  });

  final DateTime month;
  final Map<int, _DaySummary> days;
  final bool loading;
  final DateTime? selectedDay;
  final bool canGoBack;
  final bool canGoForward;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<DateTime> onDaySelected;

  static const _weekdayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Weeks start on Monday.
    final leading = DateTime(month.year, month.month).weekday - 1;
    final cells = leading + daysInMonth;
    final weeks = (cells / 7).ceil();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        // Swipe between months, like a paper calendar.
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v > 300 && canGoBack) {
            onMonthChanged(DateTime(month.year, month.month - 1));
          } else if (v < -300 && canGoForward) {
            onMonthChanged(DateTime(month.year, month.month + 1));
          }
        },
        child: Column(
          children: [
            SizedBox(
              height: 3,
              child: loading ? const LinearProgressIndicator() : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Previous month',
                        onPressed: canGoBack
                            ? () => onMonthChanged(
                                DateTime(month.year, month.month - 1),
                              )
                            : null,
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Expanded(
                        child: Text(
                          '${monthNames[month.month - 1]} ${month.year}',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Next month',
                        onPressed: canGoForward
                            ? () => onMonthChanged(
                                DateTime(month.year, month.month + 1),
                              )
                            : null,
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      for (final letter in _weekdayLetters)
                        Expanded(
                          child: Center(
                            child: Text(
                              letter,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (var week = 0; week < weeks; week++)
                    Row(
                      children: [
                        for (var weekday = 0; weekday < 7; weekday++)
                          Expanded(
                            child: Builder(
                              builder: (context) {
                                final dayNumber =
                                    week * 7 + weekday - leading + 1;
                                if (dayNumber < 1 || dayNumber > daysInMonth) {
                                  return const SizedBox(height: 46);
                                }
                                final day = DateTime(
                                  month.year,
                                  month.month,
                                  dayNumber,
                                );
                                return _DayCell(
                                  day: dayNumber,
                                  summary: days[dayNumber],
                                  isToday: day == today,
                                  isFuture: day.isAfter(today),
                                  isSelected: day == selectedDay,
                                  onTap: () => onDaySelected(day),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.summary,
    required this.isToday,
    required this.isFuture,
    required this.isSelected,
    required this.onTap,
  });

  final int day;
  final _DaySummary? summary;
  final bool isToday;
  final bool isFuture;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasTrips = summary != null;

    final Color? fill;
    final Color textColor;
    if (isSelected) {
      fill = scheme.primary;
      textColor = scheme.onPrimary;
    } else if (hasTrips) {
      fill = scheme.primaryContainer;
      textColor = scheme.onPrimaryContainer;
    } else {
      fill = null;
      textColor = isFuture
          ? scheme.onSurface.withValues(alpha: 0.25)
          : scheme.onSurfaceVariant;
    }
    final km = hasTrips ? formatDayKilometers(summary!.distanceMeters) : '';

    return SizedBox(
      height: 46,
      child: Center(
        child: Material(
          color: fill ?? Colors.transparent,
          // A circle for the usual day, a pill once the km label needs the room.
          shape: StadiumBorder(
            side: isToday && !isSelected
                ? BorderSide(color: scheme.primary, width: 1.5)
                : BorderSide.none,
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            // Only days with trips lead anywhere.
            onTap: hasTrips ? onTap : null,
            child: Container(
              height: 40,
              constraints: const BoxConstraints(minWidth: 40),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$day',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: textColor,
                      fontWeight: hasTrips || isToday
                          ? FontWeight.w700
                          : FontWeight.w400,
                      height: 1.1,
                    ),
                  ),
                  if (km.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        km,
                        maxLines: 1,
                        style: theme.textTheme.labelSmall?.copyWith(
                          // Quieter than the day number it sits under.
                          color: textColor.withValues(alpha: 0.7),
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          height: 1,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown until a day is picked: the month at a glance plus what to do next.
class _MonthOverview extends StatelessWidget {
  const _MonthOverview({required this.days});

  final Map<int, _DaySummary> days;

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) {
      return const _Message(
        icon: Icons.event_busy_rounded,
        text: 'No trips this month.',
      );
    }
    final theme = Theme.of(context);
    final trips = days.values.fold<int>(0, (sum, d) => sum + d.trips);
    final meters = days.values.fold<double>(
      0,
      (sum, d) => sum + d.distanceMeters,
    );
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _OverviewStat(value: '$trips', label: 'Trips'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _OverviewStat(
                value: '${days.length}',
                label: days.length == 1 ? 'Day' : 'Days',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _OverviewStat(
                value: formatDistance(meters),
                label: 'Distance',
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.touch_app_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              'Pick a highlighted day to see its trips',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _OverviewStat extends StatelessWidget {
  const _OverviewStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DayTrips extends StatelessWidget {
  const _DayTrips({
    required this.day,
    required this.summary,
    required this.sessions,
    required this.user,
    this.onDeleteDay,
    this.onDeleteTrip,
  });

  final DateTime day;
  final _DaySummary? summary;
  final Future<List<LocationSession>> sessions;
  final UserProfile user;

  /// Null when these aren't your trips (or a deletion is already running).
  final VoidCallback? onDeleteDay;
  final ValueChanged<LocationSession>? onDeleteTrip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  formatLongDay(day),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            if (summary != null && onDeleteDay != null)
              IconButton(
                tooltip: 'Delete this day\'s trips',
                onPressed: onDeleteDay,
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        if (summary != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
            child: Text(
              summary!.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 14),
        FutureBuilder<List<LocationSession>>(
          future: sessions,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return const _Message(
                icon: Icons.cloud_off_rounded,
                text: 'Couldn\'t load this day\'s trips.',
              );
            }
            final trips = snapshot.data ?? const [];
            if (trips.isEmpty) {
              return const _Message(
                icon: Icons.event_busy_rounded,
                text: 'No trips on this day.',
              );
            }
            return Column(
              children: [
                for (final trip in trips)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _TripCard(
                      session: trip,
                      onDelete: onDeleteTrip == null
                          ? null
                          : () => onDeleteTrip!(trip),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SessionReplayScreen(
                            session: trip,
                            userId: user.id,
                            userName: user.name,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// One trip as a little timeline: departure and arrival with their streets,
/// then its stats.
class _TripCard extends StatelessWidget {
  const _TripCard({required this.session, required this.onTap, this.onDelete});

  final LocationSession session;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final startPoint = session.startPoint;
    final endPoint = session.endPoint;
    final timeStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final streetStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    Widget stop(String time, Widget street) => Row(
      children: [
        SizedBox(width: 48, child: Text(time, style: timeStyle)),
        Expanded(child: street),
      ],
    );

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _TimelineRail(),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          stop(
                            formatClock(session.startAt),
                            startPoint == null
                                ? const SizedBox.shrink()
                                : LocationStreetLabel(
                                    location: startPoint,
                                    maxLines: 1,
                                    style: streetStyle,
                                  ),
                          ),
                          const SizedBox(height: 14),
                          stop(
                            formatClock(session.endAt),
                            endPoint == null
                                ? const SizedBox.shrink()
                                : LocationStreetLabel(
                                    location: endPoint,
                                    maxLines: 1,
                                    style: streetStyle,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _StatChip(
                          icon: Icons.timelapse_rounded,
                          label: formatTripDuration(session.duration),
                        ),
                        _StatChip(
                          icon: Icons.straighten_rounded,
                          label: formatDistance(session.distanceMeters),
                        ),
                        _StatChip(
                          icon: Icons.speed_rounded,
                          label: '${session.topSpeedKmh.round()} km/h top',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (onDelete != null)
                    IconButton(
                      tooltip: 'Delete this trip',
                      onPressed: onDelete,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Green departure dot, a line, red arrival dot — matching the replay map.
class _TimelineRail extends StatelessWidget {
  const _TimelineRail();

  @override
  Widget build(BuildContext context) {
    Widget dot(Color color) => Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Colors.white, width: 2),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          dot(const Color(0xFF34C759)),
          Expanded(
            child: Container(
              width: 2,
              margin: const EdgeInsets.symmetric(vertical: 3),
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          dot(const Color(0xFFFF453A)),
        ],
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
        borderRadius: BorderRadius.circular(999),
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
