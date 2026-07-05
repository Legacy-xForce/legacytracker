import 'package:flutter/material.dart';

import '../../../data/models/location_session.dart';
import '../../../data/models/user_model.dart';
import '../../../data/network/history_service.dart';
import 'session_replay_screen.dart';
import 'tracking_location_street_label.dart';

class LocationHistoryScreen extends StatefulWidget {
  const LocationHistoryScreen({
    super.key,
    required this.user,
    required this.baseUrl,
    required this.accessToken,
  });

  final UserProfile user;
  final String baseUrl;
  final String accessToken;

  @override
  State<LocationHistoryScreen> createState() => _LocationHistoryScreenState();
}

class _LocationHistoryScreenState extends State<LocationHistoryScreen> {
  late final HistoryService _historyService;
  late DateTime _selectedDay;
  late Future<List<LocationSession>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyService = HistoryService(baseUrl: widget.baseUrl);
    _selectedDay = DateTime.now();
    _historyFuture = _load();
  }

  Future<List<LocationSession>> _load() {
    final from = DateTime(
      _selectedDay.year,
      _selectedDay.month,
      _selectedDay.day,
    );
    final to = from.add(const Duration(days: 1));
    return _historyService.fetchHistory(
      widget.accessToken,
      userId: widget.user.id,
      from: from,
      to: to,
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDay,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now,
    );
    if (picked == null) return;
    setState(() {
      _selectedDay = picked;
      _historyFuture = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.user.name} · History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today_outlined),
            tooltip: 'Choose day',
            onPressed: _pickDate,
          ),
        ],
      ),
      body: FutureBuilder<List<LocationSession>>(
        future: _historyFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Unable to load history for this day.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            );
          }

          final sessions = snapshot.data ?? const [];
          if (sessions.isEmpty) {
            return Center(
              child: Text(
                'No movement recorded on ${_formatDay(_selectedDay)}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _SessionCard(
                  session: session,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SessionReplayScreen(
                        session: session,
                        userName: widget.user.name,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.onTap});

  final LocationSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startPoint = session.startPoint;
    final endPoint = session.endPoint;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.35,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.directions_car_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '${_formatTime(session.startAt)} – ${_formatTime(session.endAt)}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (startPoint != null)
              LocationStreetLabel(
                location: startPoint,
                maxLines: 1,
                style: theme.textTheme.bodySmall,
              ),
            if (endPoint != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Icon(
                      Icons.arrow_downward,
                      size: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: LocationStreetLabel(
                        location: endPoint,
                        maxLines: 1,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatChip(
                  icon: Icons.timelapse,
                  label: _formatDuration(session.duration),
                ),
                _StatChip(
                  icon: Icons.straighten,
                  label: '${session.distanceKm.toStringAsFixed(1)} km',
                ),
                _StatChip(
                  icon: Icons.speed,
                  label: '${session.topSpeedKmh.toStringAsFixed(0)} km/h top',
                ),
              ],
            ),
          ],
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

String _formatTime(DateTime dt) {
  final local = dt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

String _formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}

String _formatDay(DateTime day) {
  final local = day.toLocal();
  final mm = local.month.toString().padLeft(2, '0');
  final dd = local.day.toString().padLeft(2, '0');
  return '${local.year}-$mm-$dd';
}
