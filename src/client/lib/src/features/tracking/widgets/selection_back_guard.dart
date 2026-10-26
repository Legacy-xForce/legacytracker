import 'package:flutter/material.dart';

/// Keeps the Android back gesture inside the people sheet while someone is
/// selected: the first back returns to the list of everyone, and only the next
/// one leaves the screen.
class SelectionBackGuard extends StatelessWidget {
  const SelectionBackGuard({
    super.key,
    required this.selectionActive,
    required this.onClearSelection,
    required this.child,
  });

  final bool selectionActive;
  final VoidCallback onClearSelection;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !selectionActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selectionActive) onClearSelection();
      },
      child: child,
    );
  }
}
