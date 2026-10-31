import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/models/api_token.dart';
import '../../data/network/api_token_service.dart';
import 'auth_provider.dart';
import '../../core/tokens.dart';

/// The requests made with one API token, newest first. A page of its own
/// because the list can grow and the row that opens it is already crowded.
class ApiTokenRequestsScreen extends StatefulWidget {
  const ApiTokenRequestsScreen({
    super.key,
    required this.token,
    this.service,
    this.accessToken,
  });

  final ApiToken token;

  /// Overrides for tests; by default the production service and the signed-in
  /// session's token.
  final ApiTokenService? service;
  final Future<String> Function()? accessToken;

  @override
  State<ApiTokenRequestsScreen> createState() => _ApiTokenRequestsScreenState();
}

class _ApiTokenRequestsScreenState extends State<ApiTokenRequestsScreen> {
  late final ApiTokenService _service =
      widget.service ?? ApiTokenService(baseUrl: AppConstants.backendBaseUrl);

  List<ApiTokenRequest>? _requests;
  String? _nextBefore;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String> _accessToken() =>
      widget.accessToken?.call() ??
      context.read<AuthProvider>().freshAccessToken();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _service.requests(
        await _accessToken(),
        widget.token.id,
      );
      if (!mounted) return;
      setState(() {
        _requests = page.requests;
        _nextBefore = page.nextBefore;
        _hasMore = page.hasMore;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final before = _nextBefore;
    if (!_hasMore || _loadingMore || before == null) return;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final page = await _service.requests(
        await _accessToken(),
        widget.token.id,
        before: before,
      );
      if (!mounted) return;
      setState(() {
        _requests = [...?_requests, ...page.requests];
        _nextBefore = page.nextBefore;
        _hasMore = page.hasMore;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final requests = _requests;

    return Scaffold(
      appBar: AppBar(title: const Text('Request history')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.history_rounded,
                        size: 22,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.token.name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.token.hint,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          if (widget.token.userName != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Owner: ${widget.token.userName}',
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            'Every request made with this token, including '
                            'ones refused by its scope or allowed addresses. '
                            'Query strings are never stored.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              _Notice(
                icon: Icons.cloud_off_rounded,
                text: _error!,
                action: TextButton(
                  onPressed: _loading ? null : _load,
                  child: const Text('Retry'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_loading && requests == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (requests == null)
              const SizedBox.shrink()
            else if (requests.isEmpty)
              const _Notice(
                icon: Icons.history_toggle_off_rounded,
                text:
                    'No requests yet. Anything using this token will show up '
                    'here.',
              )
            else
              for (final request in requests) ...[
                _RequestTile(request: request),
                const SizedBox(height: 8),
              ],
            if (_hasMore) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: _loadingMore ? null : _loadMore,
                  icon: _loadingMore
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.history_rounded),
                  label: const Text('Load older'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.request});

  final ApiTokenRequest request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = request.statusCode >= 400;
    final meta = [
      '${formatShortDate(request.createdAt)}, ${formatClock(request.createdAt)}',
      if (request.clientIp != null) request.clientIp!,
      if (request.durationMs != null) '${request.durationMs} ms',
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Badge(
                  text: request.method,
                  background: scheme.surfaceContainerHighest,
                  foreground: scheme.onSurface,
                ),
                const SizedBox(width: 6),
                _Badge(
                  text: '${request.statusCode}',
                  background: failed
                      ? scheme.errorContainer
                      : scheme.secondaryContainer,
                  foreground: failed
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    request.path,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              meta,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (request.userAgent != null)
              Text(
                request.userAgent!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppShape.sm,
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.action});

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
