import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../location/tracking_engine.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  List<TrackingLogEntry> _entries = [];
  TrackingStatus _summary = const TrackingStatus();
  String? _categoryFilter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await TrackingEngine.logs();
    final summary = await TrackingEngine.status();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _summary = summary;
      _loading = false;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Activity log copied to clipboard')),
    );
  }

  String _report() {
    final s = _summary;
    final buffer = StringBuffer()
      ..writeln('== Activity log ==')
      ..writeln('generated: ${DateTime.now().toIso8601String()}')
      ..writeln('mode: ${s.mode.name}${s.live ? ' (live)' : ''}')
      ..writeln('configured: ${s.configured}, auth failed: ${s.authFailed}')
      ..writeln('pending points: ${s.pending}')
      ..writeln('last fix: ${s.lastFixAt?.toIso8601String() ?? "never"}')
      ..writeln('last upload: ${s.lastUploadAt?.toIso8601String() ?? "never"}')
      ..writeln('last upload error: ${s.lastUploadError ?? "—"}')
      ..writeln(
        'permissions: precise=${s.preciseLocation} '
        'background=${s.backgroundLocation} '
        'activity=${s.activityRecognition} '
        'batteryExempt=${s.batteryOptimizationIgnored}',
      )
      ..writeln('entries: ${_entries.length}')
      ..writeln();
    for (final e in _entries) {
      buffer.writeln(
        '${e.time.toIso8601String()}  [${e.category}]  ${e.message}',
      );
    }
    return buffer.toString();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear activity log?'),
        content: const Text('This removes all recorded events.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await TrackingEngine.clearLogs();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = _entries.map((e) => e.category).toSet().toList()..sort();
    final visible = _categoryFilter == null
        ? _entries
        : _entries.where((e) => e.category == _categoryFilter).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity log'),
        actions: [
          IconButton(
            tooltip: 'Copy to clipboard',
            icon: const Icon(Icons.copy_all),
            onPressed: _loading ? null : _copy,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _SummaryHeader(summary: _summary),
                const Divider(height: 1),
                if (categories.isNotEmpty)
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: const Text('All'),
                            selected: _categoryFilter == null,
                            onSelected: (_) => setState(() => _categoryFilter = null),
                          ),
                        ),
                        for (final cat in categories)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(cat),
                              selected: _categoryFilter == cat,
                              onSelected: (_) => setState(() => _categoryFilter = cat),
                            ),
                          ),
                      ],
                    ),
                  ),
                const Divider(height: 1),
                Expanded(
                  child: visible.isEmpty
                      ? const Center(child: Text('No activity recorded yet'))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final entry = visible[index];
                              return ListTile(
                                dense: true,
                                leading: _CategoryBadge(category: entry.category),
                                title: Text(entry.message),
                                subtitle: Text(_formatTimestamp(entry.time)),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  String _formatTimestamp(DateTime ts) {
    final local = ts.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.summary});

  final TrackingStatus summary;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(
            'Mode',
            '${summary.mode.name}${summary.live ? ' · live' : ''}'
                '${summary.lowPower ? ' · battery saver' : ''}',
            style,
          ),
          _row('Waiting', '${summary.pending} point(s)', style),
          _row('Last fix', _ago(summary.lastFixAt), style),
          _row('Last upload', _ago(summary.lastUploadAt), style),
          if (summary.lastUploadError != null)
            _row('Upload error', summary.lastUploadError!, style),
        ],
      ),
    );
  }

  Widget _row(String label, String value, TextStyle? style) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      children: [
        SizedBox(width: 96, child: Text(label, style: style)),
        Text(
          value,
          style: style?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  String _ago(DateTime? t) {
    if (t == null) return 'never';
    final d = DateTime.now().difference(t.toLocal());
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(category, Theme.of(context).colorScheme);
    return Container(
      width: 10,
      height: 10,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Color _colorFor(String category, ColorScheme scheme) {
    switch (category) {
      case 'position':
      case 'ping':
        return scheme.primary;
      case 'state':
      case 'live':
      case 'activity':
      case 'geofence':
        return scheme.tertiary;
      case 'upload':
      case 'auth':
        return scheme.secondary;
      case 'lifecycle':
      case 'config':
        return scheme.outline;
      default:
        return scheme.error;
    }
  }
}
