import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../utils/money.dart';
import '../data/v2_game_providers.dart';
import '../data/v2_game_repository.dart';
import 'v2_game_flow_screen.dart';

final Set<String> _handledAcceptanceInvitationIds = {};

/// Shows the post-accept buy-in dialog. Returns true if the user saved.
Future<bool> showJoinAcceptedBuyInDialog({
  required BuildContext context,
  required WidgetRef ref,
  required int sessionId,
  String? invitationId,
}) async {
  if (invitationId != null) {
    if (_handledAcceptanceInvitationIds.contains(invitationId)) {
      return false;
    }
    _handledAcceptanceInvitationIds.add(invitationId);
  }
  final repository = ref.read(v2GameRepositoryProvider);
  JoinAcceptanceInfo? info;
  try {
    info = await repository.getJoinAcceptanceInfo(sessionId);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Approved, but game details could not be loaded.'),
        ),
      );
    }
    if (invitationId != null) {
      _handledAcceptanceInvitationIds.remove(invitationId);
    }
    return false;
  }
  if (!context.mounted) return false;

  final resolvedInvitationId = info.invitationId ?? invitationId;
  if (resolvedInvitationId == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No buy-in confirmation is pending.')),
    );
    return false;
  }

  final result = await showDialog<_BuyInDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _JoinAcceptedBuyInDialog(info: info!),
  );
  if (result == null || !context.mounted) {
    if (invitationId != null) {
      _handledAcceptanceInvitationIds.remove(invitationId);
    }
    return false;
  }

  try {
    await repository.confirmJoinBuyIn(
      invitationId: resolvedInvitationId,
      amountCents: result.amountCents,
    );
  } catch (_) {
    if (invitationId != null) {
      _handledAcceptanceInvitationIds.remove(invitationId);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Buy-in could not be saved. Try again.')),
      );
    }
    return false;
  }

  if (!context.mounted) return true;
  if (result.goToGame) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => V2GameFlowScreen(sessionId: sessionId),
      ),
    );
  }
  return true;
}

class _BuyInDialogResult {
  final int amountCents;
  final bool goToGame;

  const _BuyInDialogResult({required this.amountCents, required this.goToGame});
}

class _JoinAcceptedBuyInDialog extends StatefulWidget {
  final JoinAcceptanceInfo info;

  const _JoinAcceptedBuyInDialog({required this.info});

  @override
  State<_JoinAcceptedBuyInDialog> createState() =>
      _JoinAcceptedBuyInDialogState();
}

class _JoinAcceptedBuyInDialogState extends State<_JoinAcceptedBuyInDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final cents = widget.info.defaultBuyInCents;
    _controller = TextEditingController(
      text: cents <= 0 ? '' : (cents / 100).toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit({required bool goToGame}) {
    final cents = Money.tryParseCents(_controller.text);
    if (cents == null || cents <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a buy-in greater than zero.')),
      );
      return;
    }
    Navigator.pop(
      context,
      _BuyInDialogResult(amountCents: cents, goToGame: goToGame),
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return AlertDialog(
      title: const Text('Confirm your buy-in'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(info.gameName, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Host: ${info.hostName}'),
            Text('Status: ${info.phaseLabel}'),
            Text(
              'Suggested buy-in: ${Money.formatCents(info.defaultBuyInCents, symbol: '\$')}',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Your buy-in',
                border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d+(\.\d{0,2})?$')),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _submit(goToGame: false),
          child: const Text('Save'),
        ),
        FilledButton(
          onPressed: () => _submit(goToGame: true),
          child: const Text('Save and go to game'),
        ),
      ],
    );
  }
}
