import 'package:flutter/material.dart';

import 'debug_log_store.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  List<Map<String, dynamic>> _entries = [];
  String? _categoryFilter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await DebugLogStore.readAll();
    if (!mounted) return;
    setState(() {
      _entries = entries.reversed.toList();
      _loading = false;
    });
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
