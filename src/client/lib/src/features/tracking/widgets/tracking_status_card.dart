import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../location/tracking_engine.dart';
import '../../location/tracking_permissions.dart';
import '../tracking_controller.dart';
import '../../../core/tokens.dart';
import '../../../core/palette.dart';

/// What location sharing is doing right now, plus anything that silently
/// degrades it in the background — each with a one-tap fix.
class TrackingStatusCard extends StatelessWidget {
  const TrackingStatusCard({super.key, required this.controller});

  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = controller.status;
    final issues = _issues(status);
    final sharing = controller.isTracking && status.mode != TrackingMode.off;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: sharing
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _modeIcon(status),
                    size: 20,
                    color: sharing
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _modeLabel(status),
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (status.live && sharing) ...[
                            const SizedBox(width: 8),
                            const _LiveBadge(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _detail(status),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: controller.isTracking,
                  onChanged: (on) => on
                      ? controller.startTracking()
                      : controller.stopTracking(),
                ),
              ],
            ),
          ),
          for (final issue in issues) ...[
            Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      issue.message,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await issue.fix();
                      await controller.refreshStatus();
                    },
                    child: Text(issue.action),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _modeIcon(TrackingStatus status) => switch (status.mode) {
    TrackingMode.moving => Icons.route,
    TrackingMode.stationary => Icons.location_on_outlined,
    TrackingMode.off => Icons.location_off_outlined,
  };

  String _modeLabel(TrackingStatus status) {
    if (!controller.isTracking || status.mode == TrackingMode.off) {
      return 'Sharing paused';
    }
    return switch (status.mode) {
      TrackingMode.moving => 'Recording a trip',
      _ => 'Sharing · parked',
    };
  }

  String _detail(TrackingStatus status) {
    if (!controller.isTracking) {
      return 'Others see where you were last';
    }
    final parts = <String>[];
    if (status.authFailed) {
      parts.add('Uploads paused — reconnecting your account');
    } else if (status.lastUploadError != null && status.pending > 0) {
      parts.add('${status.pending} point(s) waiting for a connection');
    } else {
      parts.add('Last update ${_ago(status.lastUploadAt)}');
      if (status.pending > 0) parts.add('${status.pending} waiting');
    }
    if (status.lowPower) parts.add('battery saver');
    return parts.join(' · ');
  }

  List<_Issue> _issues(TrackingStatus status) {
    if (!controller.isTracking || !TrackingEngine.isSupported) return const [];
    return [
      if (!status.backgroundLocation)
        _Issue(
          'Allow location "All the time" so trips are recorded with the app closed.',
          'Allow',
          TrackingPermissions.requestBackgroundLocation,
        ),
      if (!status.preciseLocation)
        _Issue(
          'Turn on precise location — approximate positions can\'t record routes.',
          'Settings',
          openAppSettings,
        ),
      if (Platform.isAndroid && !status.activityRecognition)
        _Issue(
          'Allow physical activity so drives are detected right away.',
          'Allow',
          TrackingPermissions.requestActivityRecognition,
        ),
      if (Platform.isAndroid && !status.batteryOptimizationIgnored)
        _Issue(
          'Battery optimization can stop background updates on some phones.',
          'Fix',
          TrackingPermissions.requestIgnoreBatteryOptimizations,
        ),
    ];
  }

  String _ago(DateTime? time) {
    if (time == null) return 'pending';
    final d = DateTime.now().difference(time);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

class _Issue {
  const _Issue(this.message, this.action, this.fix);

  final String message;
  final String action;
  final Future<Object?> Function() fix;
}

/// "Someone is watching": devices stream in realtime.
class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    const color = AppPalette.arrival;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: AppShape.full,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, size: 7, color: color),
          const SizedBox(width: 4),
          Text(
            'LIVE',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
