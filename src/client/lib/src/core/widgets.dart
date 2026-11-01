import 'package:flutter/material.dart';

import 'tokens.dart';

/// Widgets several features share. Anything used by one screen stays there.

/// An icon, a line of text and an optional action, on a tinted card.
class Notice extends StatelessWidget {
  const Notice({
    super.key,
    required this.icon,
    required this.text,
    this.action,
  });

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// A small tinted label. [mono] sets it in the code face (ids, status codes).
class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.text,
    required this.background,
    required this.foreground,
    this.mono = false,
    this.verticalPadding = 1,
  });

  final String text;
  final Color background;
  final Color foreground;
  final bool mono;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: verticalPadding),
      decoration: BoxDecoration(color: background, borderRadius: AppShape.sm),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontFamily: mono ? 'monospace' : null,
          fontWeight: mono ? FontWeight.w700 : null,
        ),
      ),
    );
  }
}

/// A pill with a small icon and a label.
class StatChip extends StatelessWidget {
  const StatChip({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppShape.full,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(label, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

/// A centred icon with a sentence under it: empty and error states.
class MessageState extends StatelessWidget {
  const MessageState({
    super.key,
    required this.icon,
    required this.text,
    this.action,
  });

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(icon, size: 32, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
