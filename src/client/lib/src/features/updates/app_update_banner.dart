import 'dart:async';

import 'package:flutter/material.dart';

import 'app_updater.dart';
import '../../core/tokens.dart';

/// A small "update available" banner for screens shown before sign-in.
///
/// Asks the server when it appears (and again on resume after a while), so a
/// build that broke signing in can be fixed by shipping a new release: the
/// user installs it from here without being signed in. Renders nothing while
/// the app is up to date, and where the app can't update itself (iOS).
class AppUpdateBanner extends StatefulWidget {
  const AppUpdateBanner({super.key});

  /// Resuming the app checks again once the last check is this old.
  static const recheckAfter = Duration(minutes: 5);

  @override
  State<AppUpdateBanner> createState() => _AppUpdateBannerState();
}

class _AppUpdateBannerState extends State<AppUpdateBanner>
    with WidgetsBindingObserver {
  AppUpdateStatus? _status;
  StreamSubscription<AppUpdateStatus>? _changes;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _changes = AppUpdater.statusChanges.listen(_apply);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changes?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkIfStale();
  }

  /// Shows what is already known at once, then always asks the server: this
  /// screen may be all a broken build lets the user reach.
  Future<void> _start() async {
    _apply(await AppUpdater.status());
    _apply(await AppUpdater.check());
  }

  Future<void> _checkIfStale() async {
    final checked = _status?.lastCheckAt;
    if (checked != null &&
        DateTime.now().difference(checked) < AppUpdateBanner.recheckAfter) {
      return;
    }
    _apply(await AppUpdater.check());
  }

  void _apply(AppUpdateStatus? status) {
    if (status != null && mounted) setState(() => _status = status);
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    // Downloads first if needed; progress arrives through [statusChanges].
    final result = await AppUpdater.install();
    if (!mounted) return;
    setState(() => _installing = false);
    _apply(result);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final visible =
        AppUpdater.isSupported && status != null && status.updateAvailable;
    return AnimatedSize(
      duration: AppMotion.of(context, AppMotion.long),
      curve: AppMotion.standard,
      alignment: Alignment.bottomCenter,
      child: visible
          ? _buildBanner(context, status)
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _buildBanner(BuildContext context, AppUpdateStatus status) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = _installing || status.downloading;
    final foreground = scheme.onSecondaryContainer;

    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: AppShape.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.system_update_rounded, size: 22, color: foreground),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status.failed
                            ? 'Version ${status.availableVersionName} '
                                  "can't be installed"
                            : 'Version ${status.availableVersionName} '
                                  'is available',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _detail(status),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: foreground,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (busy)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: foreground,
                      ),
                    ),
                  )
                else if (!status.failed)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: _install,
                    child: Text(status.lastError == null ? 'Install' : 'Retry'),
                  ),
              ],
            ),
            if (status.downloading)
              Padding(
                padding: const EdgeInsets.fromLTRB(34, 8, 4, 2),
                child: LinearProgressIndicator(
                  value: status.progress,
                  color: foreground,
                  backgroundColor: foreground.withValues(alpha: 0.15),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _detail(AppUpdateStatus status) {
    if (status.downloading) {
      return 'Downloading… ${(status.progress! * 100).round()}%';
    }
    if (_installing) return 'Installing — the app closes for a moment';
    if (status.failed) return 'Reinstall Legacy Tracker to update.';
    if (status.lastError != null) return status.lastError!;
    final notes = status.notes ?? '';
    return notes.isNotEmpty ? notes : 'Install it to get the latest fixes.';
  }
}
