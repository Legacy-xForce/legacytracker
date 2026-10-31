import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../tracking/widgets/user_avatar.dart';
import '../updates/app_update_banner.dart';
import 'auth_provider.dart';
import '../../core/tokens.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final auth = context.watch<AuthProvider>();
    final busy = auth.isLoading;
    final error = auth.errorMessage;
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
        // Lets a fix reach users even when signing in is what broke.
        bottomNavigationBar: SafeArea(
          child: Align(
            heightFactor: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: const AppUpdateBanner(),
              ),
            ),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              // The radar rings spill past the brand mark's box on purpose.
              clipBehavior: Clip.none,
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _BrandMark(),
                    const SizedBox(height: 20),
                    Text(
                      'Legacy Tracker',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Sign in to see where everyone is.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AnimatedSize(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.topCenter,
                              child: error == null
                                  ? const SizedBox(width: double.infinity)
                                  : Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 16,
                                      ),
                                      child: _ErrorBanner(message: error),
                                    ),
                            ),
                            // Signing in happens on Legacy Auth's own page
                            // (password or passkey) in the system browser.
                            FilledButton(
                              onPressed: busy
                                  ? null
                                  : () => context.read<AuthProvider>().signIn(),
                              child: busy
                                  ? _ButtonSpinner(color: scheme.onPrimary)
                                  : const Text('Sign in with Legacy'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'One Legacy account for the tracker and the calendar, '
                      'with a password or a passkey.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The app's mark: a location badge at the center of faint radar rings,
/// with a few people (in the avatar palette) out on the rings.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 112,
      child: CustomPaint(
        painter: _RadarPainter(
          ring: scheme.primary,
          background: scheme.surface,
        ),
        child: Center(
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [scheme.primaryContainer, scheme.secondaryContainer],
              ),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.45),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.25),
                  blurRadius: 28,
                ),
              ],
            ),
            child: Icon(
              Icons.share_location_rounded,
              size: 40,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.ring, required this.background});

  final Color ring;
  final Color background;

  static const _radii = [62.0, 98.0, 138.0, 180.0];

  // (ring index, angle in degrees, palette user id) — fixed so the mark
  // looks the same every time.
  static const _people = [
    (1, -38.0, 'a'),
    (2, 202.0, 'e'),
    (0, 160.0, 'c'),
    (3, -8.0, 'f'),
    (2, 300.0, 'b'),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);

    canvas.drawCircle(
      center,
      _radii.last,
      Paint()
        ..shader = RadialGradient(
          colors: [ring.withValues(alpha: 0.16), ring.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: center, radius: _radii.last)),
    );

    for (var i = 0; i < _radii.length; i++) {
      final color = ring.withValues(alpha: 0.30 - i * 0.07);
      final bounds = Rect.fromCircle(center: center, radius: _radii[i]);
      canvas.drawCircle(
        center,
        _radii[i],
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          // Fade out below the badge so the title sits on a clean background.
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0.5, 0.78],
          ).createShader(bounds),
      );
    }

    for (final (ringIndex, degrees, userId) in _people) {
      final angle = degrees * math.pi / 180;
      final radius = _radii[ringIndex];
      final at = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      // Outer rings fade, like the circles they sit on.
      final alpha = 1.0 - ringIndex * 0.2;
      canvas.drawCircle(at, 6.5, Paint()..color = background);
      canvas.drawCircle(
        at,
        4.5,
        Paint()..color = userColor(userId).withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) =>
      oldDelegate.ring != ring || oldDelegate.background != background;
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: AppShape.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 20,
              color: scheme.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          ],
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
      dimension: 20,
      child: CircularProgressIndicator(strokeWidth: 2.2, color: color),
    );
  }
}
