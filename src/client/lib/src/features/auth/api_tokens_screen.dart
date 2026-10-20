import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/models/api_token.dart';
import '../../data/network/api_token_service.dart';
import 'auth_provider.dart';

/// Lists the account's personal API tokens and creates, rotates or deletes
/// them. A token's value is shown once, right after it is created or rotated.
class ApiTokensScreen extends StatefulWidget {
  const ApiTokensScreen({super.key, this.service, this.accessToken});

  /// Overrides for tests; by default the production service and the signed-in
  /// session's token.
  final ApiTokenService? service;
  final Future<String> Function()? accessToken;

  @override
  State<ApiTokensScreen> createState() => _ApiTokensScreenState();
}

class _ApiTokensScreenState extends State<ApiTokensScreen> {
  late final ApiTokenService _service =
      widget.service ?? ApiTokenService(baseUrl: AppConstants.backendBaseUrl);

  List<ApiToken>? _tokens;
  bool _loading = true;
  String? _loadError;
  IssuedApiToken? _issued;

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
      _loadError = null;
    });
    try {
      final tokens = await _service.list(await _accessToken());
      if (mounted) setState(() => _tokens = tokens);
    } catch (error) {
      if (mounted) setState(() => _loadError = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final request = await showModalBottomSheet<_NewToken>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CreateTokenSheet(),
    );
    if (request == null || !mounted) return;
    try {
      final issued = await _service.create(
        await _accessToken(),
        name: request.name,
        scope: request.scope,
      );
      if (!mounted) return;
      setState(() {
        _tokens = [issued.token, ...?_tokens];
        _issued = issued;
      });
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _rotate(ApiToken token) async {
    final confirmed = await _confirm(
      title: 'Rotate token?',
      message:
          '"${token.name}" gets a new value and the current one stops working '
          'right away. Update anything that uses it.',
      action: 'Rotate',
    );
    if (!confirmed || !mounted) return;
    try {
      final issued = await _service.rotate(await _accessToken(), token.id);
      if (!mounted) return;
      setState(() {
        _tokens = [
          for (final t in _tokens ?? const <ApiToken>[])
            t.id == token.id ? issued.token : t,
        ];
        _issued = issued;
      });
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _delete(ApiToken token) async {
    final confirmed = await _confirm(
      title: 'Delete token?',
      message: 'Anything using "${token.name}" will stop working right away.',
      action: 'Delete',
    );
    if (!confirmed || !mounted) return;
    try {
      await _service.delete(await _accessToken(), token.id);
      if (!mounted) return;
      setState(() {
        _tokens = _tokens?.where((t) => t.id != token.id).toList();
        if (_issued?.token.id == token.id) _issued = null;
      });
      _showMessage('Token deleted.');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 40),
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = _tokens;
    final issued = _issued;

    return Scaffold(
      appBar: AppBar(title: const Text('API tokens')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            const _Intro(),
            if (issued != null) ...[
              const SizedBox(height: 16),
              _IssuedCard(
                issued: issued,
                onCopied: () => _showMessage('Token copied.'),
                onDone: () => setState(() => _issued = null),
              ),
            ],
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                'ON YOUR ACCOUNT',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            if (_loading && tokens == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loadError != null && tokens == null)
              _Notice(
                icon: Icons.cloud_off_rounded,
                text: _loadError!,
                action: TextButton(
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
              )
            else if (tokens!.isEmpty)
              const _Notice(
                icon: Icons.key_off_outlined,
                text: 'No tokens yet. Create one to connect another app.',
              )
            else
              for (final token in tokens) ...[
                _TokenTile(
                  token: token,
                  onRotate: () => _rotate(token),
                  onDelete: () => _delete(token),
                ),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading && tokens == null ? null : _create,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create a token'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewToken {
  const _NewToken(this.name, this.scope);

  final String name;
  final ApiTokenScope scope;
}

class _CreateTokenSheet extends StatefulWidget {
  const _CreateTokenSheet();

  @override
  State<_CreateTokenSheet> createState() => _CreateTokenSheetState();
}

class _CreateTokenSheetState extends State<_CreateTokenSheet> {
  final _name = TextEditingController();
  ApiTokenScope _scope = ApiTokenScope.read;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_NewToken(_name.text.trim(), _scope));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'New API token',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 60,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Home Assistant',
              prefixIcon: Icon(Icons.label_outline_rounded),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ApiTokenScope>(
            segments: const [
              ButtonSegment(
                value: ApiTokenScope.read,
                icon: Icon(Icons.visibility_outlined),
                label: Text('Read'),
              ),
              ButtonSegment(
                value: ApiTokenScope.write,
                icon: Icon(Icons.edit_outlined),
                label: Text('Write'),
              ),
            ],
            selected: {_scope},
            onSelectionChanged: (selection) =>
                setState(() => _scope = selection.first),
          ),
          const SizedBox(height: 10),
          Text(
            _scope == ApiTokenScope.read
                ? 'Can see locations, trips, places and the live map.'
                : 'Can do everything you can, including uploading locations '
                      'and deleting your history.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _submit, child: const Text('Create token')),
        ],
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
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
                Icons.api_rounded,
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
                    'Connect other apps',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Scripts and other apps can use the tracker as you by '
                    'sending a token in the X-API-Token header. Tokens don\'t '
                    'expire, so rotate or delete any you no longer trust. The '
                    'API is documented at /docs on the web map.',
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
    );
  }
}

class _IssuedCard extends StatelessWidget {
  const _IssuedCard({
    required this.issued,
    required this.onCopied,
    required this.onDone,
  });

  final IssuedApiToken issued;
  final VoidCallback onCopied;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Copy "${issued.token.name}" now',
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'You won\'t be able to see this token again.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      issued.value,
                      key: const ValueKey('issued-token'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy token',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: issued.value),
                      );
                      onCopied();
                    },
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onDone, child: const Text('Done')),
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenTile extends StatelessWidget {
  const _TokenTile({
    required this.token,
    required this.onRotate,
    required this.onDelete,
  });

  final ApiToken token;
  final VoidCallback onRotate;
  final VoidCallback onDelete;

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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
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
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: write
                              ? scheme.errorContainer
                              : scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          write ? 'WRITE' : 'READ',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: write
                                ? scheme.onErrorContainer
                                : scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
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
                ],
              ),
            ),
            IconButton(
              tooltip: 'Rotate ${token.name}',
              icon: const Icon(Icons.autorenew_rounded),
              onPressed: onRotate,
            ),
            IconButton(
              tooltip: 'Delete ${token.name}',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: onDelete,
            ),
          ],
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
