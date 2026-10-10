import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../data/models/passkey.dart';
import 'auth_provider.dart';

/// Lists the account's passkeys and creates or removes them.
class PasskeysScreen extends StatefulWidget {
  const PasskeysScreen({super.key});

  @override
  State<PasskeysScreen> createState() => _PasskeysScreenState();
}

class _PasskeysScreenState extends State<PasskeysScreen> {
  /// Null while loading, or when the server has passkeys turned off
  /// ([_enabled] tells which).
  List<Passkey>? _passkeys;
  bool _enabled = true;
  bool _loading = true;
  String? _loadError;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final passkeys = await context.read<AuthProvider>().loadPasskeys();
      if (!mounted) return;
      setState(() {
        _passkeys = passkeys;
        _enabled = passkeys != null;
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    try {
      final passkey = await context.read<AuthProvider>().createPasskey();
      if (!mounted || passkey == null) return;
      setState(() => _passkeys = [...?_passkeys, passkey]);
      _showMessage('Passkey created. Use it the next time you sign in.');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _remove(Passkey passkey) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove passkey?'),
        content: Text(
          'You won\'t be able to sign in with the passkey saved in '
          '${passkey.name} anymore. You can still sign in with your password.',
        ),
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
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await context.read<AuthProvider>().deletePasskey(passkey.id);
      if (!mounted) return;
      setState(() {
        _passkeys = _passkeys?.where((p) => p.id != passkey.id).toList();
      });
      _showMessage('Passkey removed.');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final passkeys = _passkeys;

    return Scaffold(
      appBar: AppBar(title: const Text('Passkeys')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            const _Intro(),
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
            if (_loading && passkeys == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loadError != null && passkeys == null)
              _Notice(
                icon: Icons.cloud_off_rounded,
                text: _loadError!,
                action: TextButton(onPressed: _load, child: const Text('Retry')),
              )
            else if (!_enabled)
              const _Notice(
                icon: Icons.info_outline_rounded,
                text: 'Passkey sign-in isn\'t turned on for your account\'s '
                    'server yet.',
              )
            else if (passkeys!.isEmpty)
              const _Notice(
                icon: Icons.key_off_outlined,
                text: 'No passkeys yet. Create one to sign in without your '
                    'password.',
              )
            else
              for (final passkey in passkeys) ...[
                _PasskeyTile(passkey: passkey, onRemove: () => _remove(passkey)),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 16),
            if (_enabled)
              FilledButton.icon(
                onPressed: _creating || _loading ? null : _create,
                icon: _creating
                    ? SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: theme.colorScheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.add_rounded),
                label: const Text('Create a passkey'),
              ),
          ],
        ),
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
                Icons.fingerprint_rounded,
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
                    'Sign in without a password',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'A passkey unlocks your account with your fingerprint, '
                    'face or screen lock. It\'s kept by your phone\'s password '
                    'manager, so there\'s nothing to remember and nothing that '
                    'can be phished.',
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

class _PasskeyTile extends StatelessWidget {
  const _PasskeyTile({required this.passkey, required this.onRemove});

  final Passkey passkey;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.key_rounded, size: 20, color: scheme.primary),
        ),
        title: Text(passkey.name),
        subtitle: Text(_details(passkey)),
        trailing: IconButton(
          tooltip: 'Remove',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: onRemove,
        ),
      ),
    );
  }

  static String _details(Passkey passkey) {
    final lastUsed = passkey.lastUsedAt;
    return [
      if (passkey.synced) 'Synced',
      'Added ${formatShortDate(passkey.createdAt)}',
      if (lastUsed != null) 'used ${_ago(lastUsed)}',
    ].join(' · ');
  }

  static String _ago(DateTime time) {
    final elapsed = DateTime.now().difference(time);
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
    if (elapsed.inDays < 1) return '${elapsed.inHours} h ago';
    return formatShortDate(time);
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
