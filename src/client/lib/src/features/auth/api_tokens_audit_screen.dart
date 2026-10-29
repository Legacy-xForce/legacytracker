import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/models/api_token.dart';
import '../../data/network/api_token_service.dart';
import 'api_token_requests_screen.dart';
import 'auth_provider.dart';

/// Every token on the tracker, grouped by owner, with each one's request
/// history a tap away. Any signed-in user can open it: auditing what
/// integrations can read or write is the point.
class ApiTokensAuditScreen extends StatefulWidget {
  const ApiTokensAuditScreen({super.key, this.service, this.accessToken});

  /// Overrides for tests; by default the production service and the signed-in
  /// session's token.
  final ApiTokenService? service;
  final Future<String> Function()? accessToken;

  @override
  State<ApiTokensAuditScreen> createState() => _ApiTokensAuditScreenState();
}

class _ApiTokensAuditScreenState extends State<ApiTokensAuditScreen> {
  late final ApiTokenService _service =
      widget.service ?? ApiTokenService(baseUrl: AppConstants.backendBaseUrl);

  List<ApiToken>? _tokens;
  bool _loading = true;
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
      final tokens = await _service.listAll(await _accessToken());
      if (mounted) setState(() => _tokens = tokens);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openRequests(ApiToken token) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ApiTokenRequestsScreen(
          token: token,
          service: _service,
          accessToken: _accessToken,
        ),
      ),
    );
  }

  List<_OwnerGroup> get _groups {
    final groups = <_OwnerGroup>[];
    for (final token in _tokens ?? const <ApiToken>[]) {
      final name = token.userName ?? 'Unknown user';
      if (groups.isNotEmpty && groups.last.name == name) {
        groups.last.tokens.add(token);
      } else {
        groups.add(_OwnerGroup(name, [token]));
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text("Everyone's tokens")),
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
                        color: scheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.groups_rounded,
                        size: 22,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Everyone can see these',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Every API token on the tracker, so anyone can '
                            'check what integrations can read or write. '
                            'Secrets are never shown, and deleted tokens keep '
                            'their activity visible.',
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
            if (_loading && _tokens == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_tokens == null)
              const SizedBox.shrink()
            else if (_tokens!.isEmpty)
              const _Notice(
                icon: Icons.key_off_outlined,
                text: 'No tokens on the tracker yet.',
              )
            else
              for (final group in _groups) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    group.name.toUpperCase(),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                for (final token in group.tokens) ...[
                  _AuditTokenTile(
                    token: token,
                    onTap: () => _openRequests(token),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 12),
              ],
          ],
        ),
      ),
    );
  }
}

class _OwnerGroup {
  _OwnerGroup(this.name, this.tokens);

  final String name;
  final List<ApiToken> tokens;
}

class _AuditTokenTile extends StatelessWidget {
  const _AuditTokenTile({required this.token, required this.onTap});

  final ApiToken token;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final write = token.scope == ApiTokenScope.write;
    final lastUsed = token.lastUsedAt;
    final usage = lastUsed == null
        ? 'Never used'
        : 'Used ${formatUpdatedAgo(DateTime.now().difference(lastUsed))}';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            token.name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _Badge(
                          text: write ? 'WRITE' : 'READ',
                          background: write
                              ? scheme.errorContainer
                              : scheme.secondaryContainer,
                          foreground: write
                              ? scheme.onErrorContainer
                              : scheme.onSecondaryContainer,
                        ),
                        if (token.deleted) ...[
                          const SizedBox(width: 6),
                          _Badge(
                            text: 'DELETED',
                            background: scheme.surfaceContainerHighest,
                            foreground: scheme.onSurfaceVariant,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      token.hint,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      'Created ${formatShortDate(token.createdAt)} · $usage',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (token.allowedIps.isNotEmpty)
                      Text(
                        'From ${token.allowedIps.join(', ')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Request history for ${token.name}',
                icon: const Icon(Icons.history_rounded),
                onPressed: onTap,
              ),
            ],
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
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
