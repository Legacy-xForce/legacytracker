import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'auth_provider.dart';

// The same warning/error accents as Legacy Calendar's equivalent screens, so
// both apps explain Legacy Auth decisions the same way.
const _amber = Color(0xFFFBBF24);
const _orange = Color(0xFFFB923C);
const _onOrange = Color(0xFF1C1917);
const _red = Color(0xFFF87171);

/// Shown when the account is fine but Legacy Auth hasn't granted it the
/// `tracker` scope.
class MissingScopeScreen extends StatefulWidget {
  const MissingScopeScreen({super.key});

  @override
  State<MissingScopeScreen> createState() => _MissingScopeScreenState();
}

class _MissingScopeScreenState extends State<MissingScopeScreen> {
  bool _checking = false;

  Future<void> _checkAgain() async {
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _checking = true);
    try {
      // On success the app swaps this screen out for the map.
      final granted = await auth.retryAccess();
      if (!granted && auth.accessDenial == AccessDenial.missingScope) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Still no tracker access. Ask your administrator to grant it.',
            ),
          ),
        );
      }
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Couldn\'t check your access. Check your connection and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = _checking || auth.isLoading;

    return _AccessDeniedLayout(
      accent: _amber,
      icon: Icons.shield_outlined,
      badge: 'Insufficient permissions',
      title: 'Scope Required',
      message: TextSpan(
        children: [
          const TextSpan(text: 'Your authenticated account '),
          ..._accountName(auth.username, scheme),
          const TextSpan(
            text: 'does not currently have the required permission scope ',
          ),
          const WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _ScopeChip('tracker'),
          ),
          const TextSpan(text: ' to access Legacy Tracker.'),
        ],
      ),
      notes: const [
        _Note(
          icon: Icons.key_rounded,
          iconColor: _amber,
          title: 'Scopes managed via Legacy Auth',
          body: 'Permissions and scopes are managed centrally. Please ask '
              'your administrator to grant the tracker scope to your profile.',
        ),
        _Note(
          icon: Icons.location_off_outlined,
          title: 'Location sharing is off',
          body: 'This phone doesn\'t share your location until the scope is '
              'granted.',
        ),
      ],
      actions: [
        FilledButton.icon(
          onPressed: busy ? null : _checkAgain,
          style: FilledButton.styleFrom(
            backgroundColor: _orange,
            foregroundColor: _onOrange,
            // Stays orange while checking, rather than Material's grey.
            disabledBackgroundColor: _orange.withValues(alpha: 0.6),
            disabledForegroundColor: _onOrange.withValues(alpha: 0.75),
          ),
          icon: _checking
              ? const _ButtonSpinner(color: _onOrange)
              : const Icon(Icons.refresh_rounded),
          label: const Text('Check Again'),
        ),
        _outlinedAction(
          label: 'Switch Account',
          color: scheme.onSurfaceVariant,
          border: scheme.outlineVariant,
          onPressed: busy ? null : auth.logout,
        ),
      ],
    );
  }
}

/// Shown when an administrator has disabled the account in Legacy Auth.
/// The session is already gone; the only way on is another account.
class AccountDisabledScreen extends StatelessWidget {
  const AccountDisabledScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;

    return _AccessDeniedLayout(
      accent: _red,
      icon: Icons.lock_outline_rounded,
      badge: 'Account disabled',
      title: 'Access Restricted',
      message: TextSpan(
        children: [
          const TextSpan(text: 'Your Legacy account '),
          ..._accountName(auth.username, scheme),
          const TextSpan(
            text: 'has been marked as disabled by an administrator.',
          ),
        ],
      ),
      notes: const [
        _Note(
          icon: Icons.info_outline_rounded,
          title: 'Need access restored?',
          body: 'Please contact your system administrator or support team to '
              'review your account status.',
        ),
      ],
      actions: [
        _outlinedAction(
          label: 'Switch Account / Sign In',
          color: _red,
          border: _red.withValues(alpha: 0.6),
          onPressed: auth.isLoading ? null : auth.logout,
        ),
      ],
    );
  }
}

/// "(name) " in bold, or nothing when the account's name isn't known (a
/// passkey refused before the server said whose it was).
List<InlineSpan> _accountName(String? username, ColorScheme scheme) => [
  if (username != null && username.isNotEmpty)
    TextSpan(
      text: '($username) ',
      style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface),
    ),
];

Widget _outlinedAction({
  required String label,
  required Color color,
  required Color border,
  required VoidCallback? onPressed,
}) {
  return OutlinedButton.icon(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      foregroundColor: color,
      side: BorderSide(color: border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    icon: const Icon(Icons.logout_rounded),
    label: Text(label),
  );
}

class _Note {
  const _Note({
    required this.icon,
    required this.title,
    required this.body,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String body;

  /// Defaults to the muted text color.
  final Color? iconColor;
}

/// A centered card on a soft glow of [accent]: icon, status pill, title,
/// explanation, a box of [notes], then [actions] stacked full width.
class _AccessDeniedLayout extends StatelessWidget {
  const _AccessDeniedLayout({
    required this.accent,
    required this.icon,
    required this.badge,
    required this.title,
    required this.message,
    required this.notes,
    required this.actions,
  });

  final Color accent;
  final IconData icon;
  final String badge;
  final String title;
  final InlineSpan message;
  final List<_Note> notes;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: scheme.surface,
            systemNavigationBarIconBrightness: dark
                ? Brightness.light
                : Brightness.dark,
          ),
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // The radius is relative to the screen's width, so the glow
                  // spills past the card's edges on any phone.
                  gradient: RadialGradient(
                    radius: 1.1,
                    colors: [
                      accent.withValues(alpha: 0.16),
                      accent.withValues(alpha: 0.07),
                      accent.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.5, 1],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.22),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 40,
                            offset: const Offset(0, 20),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(child: _IconTile(icon: icon, accent: accent)),
                          const SizedBox(height: 24),
                          Center(child: _StatusPill(label: badge, accent: accent)),
                          const SizedBox(height: 14),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text.rich(
                            message,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.55,
                            ),
                          ),
                          const SizedBox(height: 24),
                          _NotesBox(notes: notes),
                          const SizedBox(height: 24),
                          for (final (i, action) in actions.indexed) ...[
                            if (i > 0) const SizedBox(height: 12),
                            action,
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon, required this.accent});

  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Icon(icon, size: 32, color: accent),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.accent});

  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulsingDot(color: accent),
          const SizedBox(width: 8),
          // Wraps rather than overflowing at large text sizes.
          Flexible(
            child: Text(
              label.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: accent,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});

  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  late final Animation<double> _opacity = Tween(begin: 1.0, end: 0.35).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

class _NotesBox extends StatelessWidget {
  const _NotesBox({required this.notes});

  final List<_Note> notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          for (final (i, note) in notes.indexed) ...[
            if (i > 0) const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    note.icon,
                    size: 18,
                    color: note.iconColor ?? scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        note.title,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        note.body,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip(this.scope);

  final String scope;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        scope,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          color: _amber,
        ),
      ),
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2.2, color: color),
    );
  }
}
