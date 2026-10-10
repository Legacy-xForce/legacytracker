import 'dart:async';

import 'package:flutter/material.dart';

import 'app_updater.dart';

/// Installed version, update state, and the one setting that makes updates
/// silent. Renders nothing where the app can't update itself (iOS).
class AppUpdatesCard extends StatefulWidget {
  const AppUpdatesCard({super.key});

  @override
  State<AppUpdatesCard> createState() => _AppUpdatesCardState();
}

class _AppUpdatesCardState extends State<AppUpdatesCard>
    with WidgetsBindingObserver {
  AppUpdateStatus? _status;
  StreamSubscription<AppUpdateStatus>? _changes;
  bool _checking = false;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _changes = AppUpdater.statusChanges.listen(_apply);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changes?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The install permission may have been granted in Settings meanwhile.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async => _apply(await AppUpdater.status());

  void _apply(AppUpdateStatus? status) {
    if (status != null && mounted) setState(() => _status = status);
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final status = await AppUpdater.check();
    if (!mounted) return;
    setState(() => _checking = false);
    _apply(status);
    if (status != null && !status.updateAvailable && status.lastError == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You have the latest version')),
      );
    }
  }

  Future<void> _install(AppUpdateStatus status) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Install ${status.availableVersionName}?'),
        content: const Text(
          'Legacy Tracker closes for a few seconds while it updates. Open it '
          'again afterwards — location sharing carries on by itself.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Later'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _installing = true);
    final result = await AppUpdater.install();
    if (!mounted) return;
    setState(() => _installing = false);
    _apply(result);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (!AppUpdater.isSupported || status == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = _checking || _installing || status.downloading;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(
              status.updateAvailable
                  ? Icons.system_update_rounded
                  : Icons.verified_outlined,
              color: status.updateAvailable ? scheme.primary : null,
            ),
            title: Text(
              'Version ${status.currentVersionName} '
              '(${status.currentVersionCode})',
            ),
            subtitle: Text(_detail(status)),
            trailing: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : status.updateAvailable
                ? FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 36),
                    ),
                    onPressed: () => _install(status),
                    child: const Text('Install'),
                  )
                : TextButton(onPressed: _check, child: const Text('Check')),
          ),
          if (status.downloading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: LinearProgressIndicator(value: status.progress),
            ),
          if (status.updateAvailable && (status.notes ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Text(
                status.notes!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          if (!status.silentInstall) ...[
            Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      status.installPermission
                          ? 'This Android version asks you to confirm each update.'
                          : 'Allow Legacy Tracker to install apps so updates '
                                'install by themselves.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (!status.installPermission)
                    TextButton(
                      onPressed: AppUpdater.openInstallSettings,
                      child: const Text('Allow'),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _detail(AppUpdateStatus status) {
    final available = status.availableVersionName;
    if (status.downloading) {
      return 'Downloading $available… ${(status.progress! * 100).round()}%';
    }
    if (_installing) return 'Installing $available…';
    if (available != null) {
      if (status.failed) {
        return 'Version $available could not be installed — see the activity log';
      }
      if (!status.downloaded) {
        return status.lastError == null
            ? 'Version $available is available'
            : 'Version $available: ${status.lastError}';
      }
      return status.silentInstall && status.automatic
          ? 'Version $available installs by itself once you leave the app'
          : 'Version $available is ready to install';
    }
    if (status.lastError != null) return status.lastError!;
    final checked = status.lastCheckAt;
    return checked == null
        ? 'Up to date'
        : 'Up to date · checked ${_ago(checked)}';
  }

  String _ago(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}
