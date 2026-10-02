import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../location/tracking_engine.dart';
import '../../location/tracking_permissions.dart';
import '../tracking_controller.dart';

/// What location sharing is doing right now, plus anything that silently
/// degrades it in the background — each with a one-tap fix.
class TrackingStatusCard extends StatelessWidget {
  const TrackingStatusCard({super.key, required this.controller});

  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = controller.status;
    final issues = _issues(status);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_modeIcon(status), color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _modeLabel(status),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (status.live)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Chip(
                      label: const Text('Live'),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: theme.colorScheme.primaryContainer,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 34, right: 8),
              child: Text(
                _detail(status),
                style: theme.textTheme.bodySmall,
              ),
            ),
            for (final issue in issues)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 20,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(issue.message, style: theme.textTheme.bodySmall),
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
        ),
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
      return 'Location sharing paused';
    }
    return switch (status.mode) {
      TrackingMode.moving => 'Recording a trip',
      _ => 'Sharing · parked',
    };
  }

  String _detail(TrackingStatus status) {
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
