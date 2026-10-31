import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'connection_monitor.dart';
import '../../core/tokens.dart';
import '../../core/palette.dart';

/// Wraps the whole app so the banner floats over every screen, pushed routes
/// included, without any of them having to know about it.
class ConnectionBannerOverlay extends StatelessWidget {
  const ConnectionBannerOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Consumer<ConnectionMonitor>(
                builder: (context, monitor, _) => ConnectionBanner(
                  quality: monitor.quality,
                  visible: monitor.bannerVisible,
                  onDismiss: monitor.dismiss,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Red when offline, yellow on a poor connection. Slides in and out.
class ConnectionBanner extends StatefulWidget {
  const ConnectionBanner({
    super.key,
    required this.quality,
    required this.visible,
    required this.onDismiss,
  });

  final ConnectionQuality quality;
  final bool visible;
  final VoidCallback onDismiss;

  @override
  State<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends State<ConnectionBanner> {
  // Kept while sliding out, when [widget.quality] is already back to good.
  ConnectionQuality _shown = ConnectionQuality.poor;

  @override
  void initState() {
    super.initState();
    if (widget.quality != ConnectionQuality.good) _shown = widget.quality;
  }

  @override
  void didUpdateWidget(covariant ConnectionBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.quality != ConnectionQuality.good) _shown = widget.quality;
  }

  @override
  Widget build(BuildContext context) {
    final offline = _shown == ConnectionQuality.offline;
    final style = offline ? _offlineStyle : _poorStyle;

    return AnimatedSlide(
      offset: widget.visible ? Offset.zero : const Offset(0, -1.5),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: Semantics(
            liveRegion: true,
            container: true,
            child: Material(
              color: style.background,
              elevation: 2,
              shadowColor: AppPalette.black.withValues(alpha: 0.54),
              borderRadius: AppShape.lg,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                child: Row(
                  children: [
                    Icon(
                      offline ? Icons.wifi_off_rounded : Icons.network_check_rounded,
                      color: style.foreground,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            offline ? "You're offline" : 'Poor connection',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: style.foreground,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            offline
                                ? "The map and other people's positions won't update until you're back online."
                                : 'The map may load slowly and positions may update late.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: style.foreground.withValues(
                                    alpha: 0.85,
                                  ),
                                ),
                          ),
                        ],
                      ),
                    ),
                    // No tooltip: the banner sits above the Navigator, so there
                    // is no Overlay for one to show in.
                    Semantics(
                      label: 'Dismiss',
                      button: true,
                      excludeSemantics: true,
                      child: IconButton(
                        onPressed: widget.onDismiss,
                        icon: Icon(Icons.close_rounded, color: style.foreground),
                        visualDensity: VisualDensity.compact,
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

class _BannerStyle {
  const _BannerStyle(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

const _offlineStyle = _BannerStyle(AppPalette.offlineBanner, AppPalette.onOfflineBanner);
const _poorStyle = _BannerStyle(AppPalette.poorBanner, AppPalette.onPoorBanner);
