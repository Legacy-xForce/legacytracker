import 'package:flutter/material.dart';

/// Keeps Android back presses inside the tracking screen while they have
/// something to undo there: from the Travel/Profile tab it returns to the
/// map, and on the map with someone selected the first back returns to the
/// list of everyone. Only once neither is true does a press leave the
/// screen.
class SelectionBackGuard extends StatelessWidget {
  const SelectionBackGuard({
    super.key,
    required this.consumeBack,
    required this.onBack,
    required this.child,
  });

  /// Whether the next back press belongs to this screen's own state.
  final bool consumeBack;

  /// Steps the screen's state back one level.
  final VoidCallback onBack;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !consumeBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && consumeBack) onBack();
      },
      child: child,
    );
  }
}
