import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/v2_game_providers.dart';
import '../domain/v2_game_models.dart';

/// Games-tab sheet: invitations waiting for the current user to accept.
Future<void> showPendingInviteeInvitationsSheet({
  required BuildContext context,
  required WidgetRef ref,
  required Future<void> Function(V2Invitation invitation) onAccepted,
}) async {
  ref.invalidate(pendingGameInvitationsProvider);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => Consumer(
      builder: (modalContext, ref, _) {
        final invitations = ref.watch(pendingGameInvitationsProvider);
        return _GameInvitationsSheetBody(
          title: 'Game invitations',
          emptyMessage: 'You have no pending invitations.',
          asyncInvitations: invitations,
          itemBuilder: (invitation) => _InvitationTile(
            title: 'Poker game invitation',
            subtitle: invitation.handle == null
                ? 'Open the invitation to respond.'
                : 'Invited as @${invitation.handle}',
            onDecline: () async {
              await ref
                  .read(v2GameRepositoryProvider)
                  .respondToInvitation(invitation.id, false);
              ref.invalidate(pendingGameInvitationsProvider);
            },
            onAccept: () async {
              await ref
                  .read(v2GameRepositoryProvider)
                  .respondToInvitation(invitation.id, true);
              ref.invalidate(pendingGameInvitationsProvider);
              if (sheetContext.mounted) Navigator.pop(sheetContext);
              await onAccepted(invitation);
            },
          ),
        );
      },
    ),
  );
}

/// In-game host sheet: join requests waiting for host approval for one game.
Future<void> showHostJoinRequestsSheet({
  required BuildContext context,
  required List<V2Invitation> joinRequests,
  required Future<void> Function(String invitationId, bool accept) onRespond,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => _GameInvitationsSheetBody(
      title: 'Join requests',
      emptyMessage: 'No pending join requests for this game.',
      invitations: joinRequests,
      itemBuilder: (invitation) => _InvitationTile(
        title: invitation.displayName,
        subtitle: invitation.handle == null
            ? 'Requested to join'
            : '@${invitation.handle}',
        onDecline: () async {
          await onRespond(invitation.id, false);
          if (sheetContext.mounted) Navigator.pop(sheetContext);
        },
        onAccept: () async {
          await onRespond(invitation.id, true);
          if (sheetContext.mounted) Navigator.pop(sheetContext);
        },
      ),
    ),
  );
}

class _GameInvitationsSheetBody extends StatelessWidget {
  final String title;
  final String emptyMessage;
  final AsyncValue<List<V2Invitation>>? asyncInvitations;
  final List<V2Invitation>? invitations;
  final Widget Function(V2Invitation invitation) itemBuilder;

  const _GameInvitationsSheetBody({
    required this.title,
    required this.emptyMessage,
    required this.itemBuilder,
    this.asyncInvitations,
    this.invitations,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: asyncInvitations != null
            ? asyncInvitations!.when(
                loading: () => const SizedBox(
                  height: 240,
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, __) => const SizedBox(
                  height: 240,
                  child: Center(
                    child: Text('Invitations could not be loaded.'),
                  ),
                ),
                data: (items) => _list(context, items),
              )
            : _list(context, invitations ?? const []),
      ),
    );
  }

  Widget _list(BuildContext context, List<V2Invitation> items) {
    return SizedBox(
      height: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          if (items.isEmpty)
            Expanded(child: Center(child: Text(emptyMessage)))
          else
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (itemContext, index) => itemBuilder(items[index]),
              ),
            ),
        ],
      ),
    );
  }
}

class _InvitationTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final Future<void> Function() onDecline;
  final Future<void> Function() onAccept;

  const _InvitationTile({
    required this.title,
    required this.subtitle,
    required this.onDecline,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.casino)),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Wrap(
          children: [
            IconButton(
              tooltip: 'Decline',
              onPressed: () => onDecline(),
              icon: const Icon(Icons.close),
            ),
            IconButton(
              tooltip: 'Accept',
              onPressed: () => onAccept(),
              icon: const Icon(Icons.check),
            ),
          ],
        ),
      ),
    );
  }
}
