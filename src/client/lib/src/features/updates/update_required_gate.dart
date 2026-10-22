import 'dart:async';

import 'package:flutter/material.dart';

import 'app_update_banner.dart';
import 'app_updater.dart';

/// Shows [child] unless the server no longer supports this build
/// (`min_supported_code`), in which case the only thing left to do is install
/// the update. Used before a backend change old builds can't follow, such as
/// the end of the password login they sign in with.
class UpdateRequiredGate extends StatefulWidget {
  const UpdateRequiredGate({super.key, required this.child});

  final Widget child;

  @override
  State<UpdateRequiredGate> createState() => _UpdateRequiredGateState();
}

class _UpdateRequiredGateState extends State<UpdateRequiredGate> {
  bool _required = false;
  StreamSubscription<AppUpdateStatus>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = AppUpdater.statusChanges.listen(_apply);
    // What the last check found, at once; the banners ask the server again.
    unawaited(AppUpdater.status().then(_apply));
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  void _apply(AppUpdateStatus? status) {
    if (status == null || !mounted) return;
    if (status.updateRequired != _required) {
      setState(() => _required = status.updateRequired);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_required) return widget.child;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.system_update_rounded,
                    size: 56,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Update required',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This version of Legacy Tracker is no longer supported. '
                    'Install the update to keep using it.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const AppUpdateBanner(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
