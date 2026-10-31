import 'package:flutter/material.dart';

import '../../../data/models/tracking_issue.dart';
import '../../../core/tokens.dart';

/// Warns that phone settings are stopping or delaying someone's location
/// updates, with an expandable "how to fix this". Renders nothing when there
/// are no [issues].
class TrackingIssuesBanner extends StatefulWidget {
  const TrackingIssuesBanner({
    super.key,
    required this.issues,
    required this.name,
    required this.isSelf,
  });

  final List<TrackingIssue> issues;
  final String name;
  final bool isSelf;

  @override
  State<TrackingIssuesBanner> createState() => _TrackingIssuesBannerState();
}

class _TrackingIssuesBannerState extends State<TrackingIssuesBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final issues = widget.issues;
    if (issues.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final accent = Colors.amber;
    final single = issues.length == 1;

    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey('tracking-issues-banner'),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: AppShape.lg,
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.location_off_rounded, color: accent, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    single
                        ? issues.first.title
                        : 'Location updates are being blocked',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  for (final issue in issues)
                    Padding(
                      padding: EdgeInsets.only(top: single ? 0 : 2),
                      child: Text(
                        single ? _summary(issue) : '•  ${_summary(issue)}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        _expanded ? 'Hide steps' : 'Learn how to fix this',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                  if (_expanded)
                    for (final issue in issues) ...[
                      const SizedBox(height: 6),
                      if (!single)
                        Text(
                          issue.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      for (final (index, step) in issue.steps.indexed)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${index + 1}. $step',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _summary(TrackingIssue issue) =>
      issue.summary(name: widget.name, self: widget.isSelf);
}
