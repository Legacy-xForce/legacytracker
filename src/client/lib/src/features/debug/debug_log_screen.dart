import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'debug_log_store.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  List<Map<String, dynamic>> _entries = [];
  DebugLogSummary _summary = const DebugLogSummary();
  String? _categoryFilter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await DebugLogStore.readAll();
    final summary = await DebugLogStore.summary();
    if (!mounted) return;
    setState(() {
      _entries = entries.reversed.toList();
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
      ..writeln('service running: ${s.serviceRunning}')
      ..writeln('app foreground: ${s.appForeground}')
      ..writeln('pacing mode: ${s.pacingMode}')
      ..writeln('interval ms: ${s.intervalMs ?? "—"}')
      ..writeln('last tick: ${s.lastTick?.toIso8601String() ?? "never"}')
      ..writeln('last success: ${s.lastSuccess?.toIso8601String() ?? "never"}')
      ..writeln('entries: ${_entries.length}')
      ..writeln();
    for (final e in _entries) {
      buffer.writeln(
        '${e['ts'] ?? '?'}  [${e['cat'] ?? '?'}]  ${e['msg'] ?? ''}',
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
      await DebugLogStore.clear();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = _entries.map((e) => e['cat'] as String? ?? '').toSet().toList()..sort();
    final visible = _categoryFilter == null
        ? _entries
        : _entries.where((e) => e['cat'] == _categoryFilter).toList();

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
                              final ts = DateTime.tryParse(entry['ts'] as String? ?? '');
                              final cat = entry['cat'] as String? ?? '';
                              final msg = entry['msg'] as String? ?? '';
                              return ListTile(
                                dense: true,
                                leading: _CategoryBadge(category: cat),
                                title: Text(msg),
                                subtitle: Text(ts != null ? _formatTimestamp(ts) : ''),
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

  final DebugLogSummary summary;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Service', summary.serviceRunning ? 'running' : 'stopped', style),
          _row('App', summary.appForeground ? 'foreground' : 'background', style),
          _row(
            'Pacing',
            summary.intervalMs == null
                ? summary.pacingMode
                : '${summary.pacingMode} · ${(summary.intervalMs! / 1000).round()}s',
            style,
          ),
          _row('Last tick', _ago(summary.lastTick), style),
          _row('Last success', _ago(summary.lastSuccess), style),
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
        return scheme.primary;
      case 'pacing':
        return scheme.tertiary;
      case 'upload':
        return scheme.secondary;
      case 'lifecycle':
        return scheme.outline;
      default:
        return scheme.error;
    }
  }
}
