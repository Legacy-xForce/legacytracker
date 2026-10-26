import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'mapbox_token_service.dart';

/// What a map screen gets once a Mapbox token is available.
class MapboxTokenSession {
  const MapboxTokenSession({
    required this.token,
    required this.generation,
    required this.recover,
  });

  final String token;

  /// Bumped only when the map has to be recreated after a load error. A normal
  /// token refresh updates [token] in place; the map keeps its camera and
  /// annotations.
  final int generation;

  final VoidCallback recover;
}

typedef MapboxTokenBuilder =
    Widget Function(BuildContext context, MapboxTokenSession session);

/// Fetches a short-lived Mapbox token before a map is built.
///
/// Release builds never embed a token, so every map waits here. While the
/// first token loads the gate shows a spinner; if the backend cannot mint one
/// it shows a retryable error instead of a blank map. Later refreshes update
/// the token in place; only a map-load error recreates the map.
class MapboxTokenGate extends StatefulWidget {
  const MapboxTokenGate({
    super.key,
    required this.builder,
    this.service,
    this.devToken = '',
    this.onTokenChanged,
  });

  final MapboxTokenBuilder builder;

  /// Created and disposed by the caller. When null, [devToken] is used (the
  /// standalone map spike or a local development run).
  final MapboxTokenService? service;
  final String devToken;
  final ValueChanged<String>? onTokenChanged;

  @override
  State<MapboxTokenGate> createState() => _MapboxTokenGateState();
}

class _MapboxTokenGateState extends State<MapboxTokenGate> {
  static const _refreshInterval = Duration(seconds: 30);
  static const _maxAutomaticRecoveries = 2;

  String? _token;
  int _generation = 0;
  bool _failed = false;
  bool _loadingInFlight = false;
  int _automaticRecoveries = 0;
  Timer? _timer;

  String get _effectiveDevToken {
    // Release builds must ignore a token compiled in for local work.
    if (kReleaseMode) return '';
    return widget.devToken;
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    if (_loadingInFlight) return;
    _loadingInFlight = true;
    try {
      String? token;
      final service = widget.service;
      if (service != null) {
        if (force) service.invalidate();
        token = await service.token;
      } else {
        final dev = _effectiveDevToken;
        token = dev.isEmpty ? null : dev;
      }
      if (!mounted) return;
      if (token != null && token.isNotEmpty) {
        final changed = token != _token;
        setState(() {
          _token = token;
          _failed = false;
          if (changed) _automaticRecoveries = 0;
        });
        if (changed) widget.onTokenChanged?.call(token);
        return;
      }
      if (_token != null) {
        // A failed background refresh must not blank an already working map.
        return;
      }
      setState(() => _failed = true);
    } finally {
      _loadingInFlight = false;
    }
  }

  Future<void> _recoverFromMapError() async {
    if (_automaticRecoveries >= _maxAutomaticRecoveries) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    _automaticRecoveries++;
    final hadToken = _token != null;
    await _refresh(force: true);
    if (!mounted) return;
    if (_token != null) {
      setState(() {
        _generation++;
        _failed = false;
      });
    } else if (!hadToken) {
      setState(() => _failed = true);
    }
  }

  Future<void> _retry() async {
    final hadToken = _token != null;
    setState(() {
      _failed = false;
      _automaticRecoveries = 0;
    });
    await _refresh(force: true);
    if (!mounted) return;
    if (_token == null) {
      setState(() => _failed = true);
    } else if (hadToken) {
      // The map itself is in a bad state; rebuild it with the fresh token.
      setState(() => _generation++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final token = _token;
    if (_failed) {
      return _MapboxTokenMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Map unavailable',
        message: widget.service == null && _effectiveDevToken.isEmpty
            ? 'Pass --dart-define=MAPBOX_TOKEN=pk.… to use the map spike.'
            : 'The token service is unavailable. Check your connection and try again.',
        onRetry: _retry,
      );
    }
    if (token != null) {
      return widget.builder(
        context,
        MapboxTokenSession(
          token: token,
          generation: _generation,
          recover: _recoverFromMapError,
        ),
      );
    }
    return const _MapboxTokenMessage(
      icon: Icons.map_outlined,
      title: 'Preparing the map…',
      message: 'Fetching a map token.',
      loading: true,
    );
  }
}

class _MapboxTokenMessage extends StatelessWidget {
  const _MapboxTokenMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox.square(
                  dimension: 32,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              else
                Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
