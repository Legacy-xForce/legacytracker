import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

enum ConnectionQuality {
  /// The backend answers promptly.
  good,

  /// The backend answers, but slowly, or a request just failed.
  poor,

  /// The backend can't be reached at all.
  offline,
}

/// Measures one round trip to the backend; throws when it can't be reached.
/// Any HTTP response counts — even an error status proves the path works.
typedef ConnectionProbe = Future<Duration> Function();

/// Watches whether the backend is reachable and how fast it answers, so the
/// UI can tell the user when lag, a stale map or missing positions are down to
/// their connection rather than the app.
///
/// It probes the backend itself instead of trusting the OS network state: a
/// phone that is "connected" to a captive or dead Wi-Fi is exactly the case the
/// user needs to hear about.
class ConnectionMonitor extends ChangeNotifier with WidgetsBindingObserver {
  ConnectionMonitor({
    ConnectionProbe? probe,
    String? baseUrl,
    this.interval = const Duration(seconds: 10),
    this.retryDelay = const Duration(seconds: 2),
    this.slowAfter = const Duration(milliseconds: 2000),
    this.recoveredBelow = const Duration(milliseconds: 1200),
    this.timeout = const Duration(seconds: 6),
  }) : assert(probe != null || baseUrl != null) {
    _probe = probe ?? _httpProbe(baseUrl!);
  }

  final Duration interval;

  /// After a failed probe, how long before checking again. Two failures in a
  /// row mean offline; a single one is only reported as poor.
  final Duration retryDelay;

  /// A response slower than this is a poor connection.
  final Duration slowAfter;

  /// Once poor, the connection has to answer faster than this to be good
  /// again, so a borderline link doesn't make the banner flicker.
  final Duration recoveredBelow;

  final Duration timeout;

  late final ConnectionProbe _probe;
  final http.Client _client = http.Client();

  ConnectionQuality _quality = ConnectionQuality.good;
  // Set when the user dismisses the banner for the current [quality]; cleared
  // as soon as the quality changes, so a new problem is never silently hidden.
  bool _dismissed = false;
  int _failures = 0;
  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _running = false;

  ConnectionQuality get quality => _quality;

  /// Whether the banner for the current problem should be on screen.
  bool get bannerVisible => _quality != ConnectionQuality.good && !_dismissed;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  void dismiss() {
    if (_quality == ConnectionQuality.good || _dismissed) return;
    _dismissed = true;
    notifyListeners();
  }

  /// Checks right away instead of waiting for the next scheduled probe.
  void recheck() {
    if (!_started || _disposed) return;
    _timer?.cancel();
    _check();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      recheck();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Nobody is looking; don't spend battery on it.
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _check() async {
    if (_running) return;
    _running = true;
    Duration? latency;
    try {
      latency = await _probe().timeout(timeout);
    } catch (_) {
      latency = null;
    }
    _running = false;
    if (_disposed) return;

    _apply(latency);
    _timer?.cancel();
    _timer = Timer(latency == null ? retryDelay : interval, _check);
  }

  void _apply(Duration? latency) {
    final ConnectionQuality next;
    if (latency == null) {
      _failures++;
      next = _failures >= 2
          ? ConnectionQuality.offline
          : (_quality == ConnectionQuality.offline
                ? ConnectionQuality.offline
                : ConnectionQuality.poor);
    } else {
      _failures = 0;
      if (latency >= slowAfter) {
        next = ConnectionQuality.poor;
      } else if (_quality != ConnectionQuality.good && latency >= recoveredBelow) {
        next = ConnectionQuality.poor;
      } else {
        next = ConnectionQuality.good;
      }
    }

    if (next == _quality) return;
    _quality = next;
    _dismissed = false;
    notifyListeners();
  }

  ConnectionProbe _httpProbe(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    return () async {
      final stopwatch = Stopwatch()..start();
      await _client.head(uri);
      return stopwatch.elapsed;
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _client.close();
    super.dispose();
  }
}
