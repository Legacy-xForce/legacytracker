import 'package:flutter/material.dart';

/// Asks the user to confirm an action; true only when they chose it.
///
/// [destructive] paints the action in the error colour. [cancelLabel] is
/// "Cancel" unless the question is a choice rather than a refusal ("Later").
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String actionLabel,
  bool destructive = false,
  String cancelLabel = 'Cancel',
}) async {
  final scheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 40),
            backgroundColor: destructive ? scheme.error : null,
            foregroundColor: destructive ? scheme.onError : null,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(actionLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}
