import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../config/app_links.dart';

/// Screenshot-style invite bottom sheet: QR, HTTPS game link, and invite code.
Future<void> showV2InviteSheet({
  required BuildContext context,
  required String gameName,
  required String? initialCode,
  required Future<String?> Function({required bool regenerate}) ensureJoinCode,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _V2InviteSheet(
      gameName: gameName,
      initialCode: initialCode,
      ensureJoinCode: ensureJoinCode,
    ),
  );
}

class _V2InviteSheet extends StatefulWidget {
  final String gameName;
  final String? initialCode;
  final Future<String?> Function({required bool regenerate}) ensureJoinCode;

  const _V2InviteSheet({
    required this.gameName,
    required this.initialCode,
    required this.ensureJoinCode,
  });

  @override
  State<_V2InviteSheet> createState() => _V2InviteSheetState();
}

class _V2InviteSheetState extends State<_V2InviteSheet> {
  String? _code;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _code = widget.initialCode;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCode());
  }

  Future<void> _loadCode({bool regenerate = false}) async {
    if (!regenerate && _code != null && _code!.isNotEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (regenerate && _code != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Generate a new join code?'),
          content: const Text(
            'Any earlier code for this game will stop working. You still '
            'approve every request.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep current code'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Generate'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final code = await widget.ensureJoinCode(regenerate: regenerate);
      if (!mounted) return;
      setState(() {
        _code = code;
        _loading = false;
        if (code == null || code.isEmpty) {
          _error = 'Could not create an invite code. Try again.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not create an invite code. Try again.';
      });
    }
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  String _spacedCode(String code) {
    final normalized = code.trim().toUpperCase();
    final buffer = StringBuffer();
    for (var i = 0; i < normalized.length; i++) {
      if (i > 0 && i % 3 == 0) buffer.write(' ');
      buffer.write(normalized[i]);
    }
    return buffer.toString();
  }

  String _truncatedUrl(String url) {
    if (url.length <= 42) return url;
    return '${url.substring(0, 22)}…${url.substring(url.length - 16)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = _code?.trim().toUpperCase();
    final inviteUrl = code == null || code.isEmpty
        ? null
        : pokerLedgerInviteUrl(code);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Invite players to ${widget.gameName}',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => _loadCode(regenerate: true),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              )
            else if (inviteUrl != null && code != null) ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.55,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: inviteUrl,
                    size: 180,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Scan to join',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              _InviteInfoRow(
                title: 'Game link',
                tooltip:
                    'Anyone with this link can request to join. You still '
                    'approve each request.',
                value: _truncatedUrl(inviteUrl),
                onCopy: () => _copy(inviteUrl, 'Game link'),
              ),
              const SizedBox(height: 10),
              _InviteInfoRow(
                title: 'Invite code',
                tooltip:
                    'Players can enter this six-letter code in Poker Ledger. '
                    'You still approve each request.',
                value: _spacedCode(code),
                onCopy: () => _copy(code, 'Invite code'),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _loadCode(regenerate: true),
                  child: const Text('New code'),
                ),
              ),
              TextButton(
                onPressed: () {
                  SharePlus.instance.share(
                    ShareParams(
                      text:
                          'Join ${widget.gameName} in Poker Ledger.\n'
                          '$inviteUrl\n'
                          'Code: $code',
                    ),
                  );
                },
                child: const Text('Share via…'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InviteInfoRow extends StatelessWidget {
  final String title;
  final String tooltip;
  final String value;
  final VoidCallback onCopy;

  const _InviteInfoRow({
    required this.title,
    required this.tooltip,
    required this.value,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      message: tooltip,
                      child: Icon(
                        Icons.info_outline,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    letterSpacing: title == 'Invite code' ? 1.2 : null,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            onPressed: onCopy,
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
    );
  }
}
