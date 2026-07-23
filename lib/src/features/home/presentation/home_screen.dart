import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../../../auth/providers/auth_providers.dart';
import '../../../utils/money.dart';
import '../../groups/data/group_providers.dart';
import '../../session/data/sessions_list_providers.dart';
import '../../session/data/v2_game_providers.dart';
import '../../session/domain/session_models.dart';
import '../../session/domain/v2_game_models.dart';
import '../../session/presentation/game_setup_wizard.dart';
import '../../session/presentation/session_summary_screen.dart';
import '../../session/presentation/sessions_home_screen.dart';
import '../../session/presentation/v2_game_flow_screen.dart';
import '../../../widgets/app_bar_action_button.dart';

final unreadNotificationsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  final rows = await Supabase.instance.client
      .from('user_notifications')
      .select('id, title, body, data, created_at')
      .eq('user_id', user.id)
      .isFilter('read_at', null)
      .order('created_at', ascending: false)
      .limit(10);
  return rows.map((row) => Map<String, dynamic>.from(row)).toList();
});

class HomeScreen extends ConsumerWidget {
  final VoidCallback onOpenGames;
  final VoidCallback onOpenGroups;

  const HomeScreen({
    super.key,
    required this.onOpenGames,
    required this.onOpenGroups,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sessions = ref.watch(sessionsListProvider);
    final openSettlements = ref.watch(openSettlementTransfersProvider);
    final gameInvitations = ref.watch(pendingGameInvitationsProvider);
    final groupInvitations = ref.watch(pendingGroupInvitationsProvider);
    final notifications = ref.watch(unreadNotificationsProvider);

    final settleCount = openSettlements.asData?.value.length ?? 0;
    final gameInviteCount = gameInvitations.asData?.value.length ?? 0;
    final groupInviteCount = groupInvitations.asData?.value.length ?? 0;
    final inviteCount = gameInviteCount + groupInviteCount;
    final notifCount = notifications.asData?.value.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text('Home'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: AppBarActionButton(
              label: 'Join',
              icon: Icons.password,
              filled: false,
              onPressed: () => enterJoinCode(context, ref),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: AppBarActionButton(
              label: 'New',
              icon: Icons.add_rounded,
              filled: true,
              onPressed: onOpenGames,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(sessionsListProvider.notifier).refresh();
          ref.invalidate(openSettlementTransfersProvider);
          ref.invalidate(pendingGameInvitationsProvider);
          ref.invalidate(pendingGroupInvitationsProvider);
          ref.invalidate(unreadNotificationsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            Text('Poker Ledger', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              'Your next required action, without the guesswork.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (settleCount > 0 || inviteCount > 0 || notifCount > 0) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (settleCount > 0)
                    _CountChip(
                      label: '$settleCount to settle',
                      color: theme.colorScheme.secondary,
                    ),
                  if (inviteCount > 0)
                    _CountChip(
                      label: '$inviteCount invite${inviteCount == 1 ? '' : 's'}',
                      color: theme.colorScheme.primary,
                    ),
                  if (notifCount > 0)
                    _CountChip(
                      label: '$notifCount new',
                      color: theme.colorScheme.tertiary,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 22),
            sessions.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: LinearProgressIndicator(),
              ),
              error: (_, __) => _Section(
                title: 'Active games',
                child: _DenseTile(
                  icon: Icons.sync_problem,
                  title: 'Games could not be loaded',
                  subtitle: 'Open Games to retry.',
                  trailing: TextButton(
                    onPressed: onOpenGames,
                    child: const Text('Open'),
                  ),
                  onTap: onOpenGames,
                ),
              ),
              data: (rows) {
                final active =
                    rows.where((row) => !row.session.finalized).toList()
                      ..sort(
                        (left, right) => right.session.startedAt.compareTo(
                          left.session.startedAt,
                        ),
                      );
                final top = active.take(3).toList();
                if (top.isEmpty) return const SizedBox.shrink();
                return _Section(
                  title: 'Active games',
                  child: Column(
                    children: [
                      for (var i = 0; i < top.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        _DenseTile(
                          icon: Icons.play_circle_outline,
                          title: top[i].session.name ?? 'Active poker game',
                          subtitle: _phaseLabel(top[i].session),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          onTap: () => _openSession(context, top[i]),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
            openSettlements.when(
              data: (transfers) {
                if (transfers.isEmpty) return const SizedBox.shrink();
                return _Section(
                  title: 'Money to settle',
                  child: Column(
                    children: [
                      for (var i = 0; i < transfers.length; i++) ...[
                        if (i > 0) const SizedBox(height: 10),
                        _SettlementRow(
                          transfer: transfers[i],
                          onStatus: (status) => _updateTransferStatus(
                            context,
                            ref,
                            transfers[i],
                            status,
                          ),
                          onOpenGame: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => V2GameFlowScreen(
                                sessionId: transfers[i].sessionId,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            Builder(
              builder: (context) {
                final gameRows = gameInvitations.asData?.value ?? const [];
                final groupRows = groupInvitations.asData?.value ?? const [];
                if (gameRows.isEmpty && groupRows.isEmpty) {
                  return const SizedBox.shrink();
                }
                return _Section(
                  title: 'Invitations',
                  child: Column(
                    children: [
                      if (gameRows.isNotEmpty)
                        _DenseTile(
                          icon: Icons.mark_email_unread_outlined,
                          title:
                              '${gameRows.length} game invitation${gameRows.length == 1 ? '' : 's'}',
                          subtitle:
                              'Accept before a game affects your stats.',
                          trailing: TextButton(
                            onPressed: onOpenGames,
                            child: const Text('Review'),
                          ),
                          onTap: onOpenGames,
                        ),
                      if (gameRows.isNotEmpty && groupRows.isNotEmpty)
                        const SizedBox(height: 8),
                      if (groupRows.isNotEmpty)
                        _DenseTile(
                          icon: Icons.group_add_outlined,
                          title:
                              '${groupRows.length} group invitation${groupRows.length == 1 ? '' : 's'}',
                          subtitle: 'Membership starts after you accept.',
                          trailing: TextButton(
                            onPressed: onOpenGroups,
                            child: const Text('Review'),
                          ),
                          onTap: onOpenGroups,
                        ),
                    ],
                  ),
                );
              },
            ),
            notifications.when(
              data: (rows) {
                if (rows.isEmpty) return const SizedBox.shrink();
                return _Section(
                  title: 'Recent notifications',
                  child: Column(
                    children: [
                      for (var i = 0; i < rows.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        _NotificationTile(
                          notification: rows[i],
                          onMarkRead: () =>
                              _markNotificationRead(ref, rows[i]['id']),
                          onTap: () => _openNotification(context, ref, rows[i]),
                        ),
                      ],
                    ],
                  ),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _updateTransferStatus(
    BuildContext context,
    WidgetRef ref,
    OpenSettlementTransfer transfer,
    String status,
  ) async {
    try {
      await ref
          .read(v2GameRepositoryProvider)
          .updateTransferStatus(transfer.transferId, status);
      ref.invalidate(openSettlementTransfersProvider);
      ref.invalidate(unreadNotificationsProvider);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not update settlement. Please try again.'),
        ),
      );
    }
  }

  Future<void> _markNotificationRead(WidgetRef ref, Object? id) async {
    await Supabase.instance.client
        .from('user_notifications')
        .update({'read_at': DateTime.now().toIso8601String()})
        .eq('id', id!);
    ref.invalidate(unreadNotificationsProvider);
  }

  Future<void> _openNotification(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> notification,
  ) async {
    final data = notification['data'] as Map?;
    final sessionIdRaw = data?['session_id'];
    final sessionId = sessionIdRaw is int
        ? sessionIdRaw
        : int.tryParse('$sessionIdRaw');
    await _markNotificationRead(ref, notification['id']);
    if (sessionId != null && context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => V2GameFlowScreen(sessionId: sessionId),
        ),
      );
    }
  }

  String _phaseLabel(Session session) {
    if (session.ledgerVersion == 1) return 'Legacy game · continue setup';
    return switch (session.phase) {
      'draft' => 'Draft · finish lobby',
      'live' => 'Live · record rebuys',
      'settling' => 'Settlement · review & finalize',
      'owner_unavailable_read_only' => 'Host unavailable · read-only',
      'orphaned_read_only' => 'Host unavailable · read-only',
      _ => 'Continue game',
    };
  }

  void _openSession(BuildContext context, SessionWithOwner row) {
    final session = row.session;
    final screen = session.ledgerVersion == 2
        ? V2GameFlowScreen(sessionId: session.id!)
        : session.finalized || !row.isOwner
        ? SessionSummaryScreen(sessionId: session.id!)
        : GameSetupWizard(sessionId: session.id!);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.3,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  final String label;
  final Color color;

  const _CountChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DenseTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _DenseTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 26, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

class _SettlementRow extends StatelessWidget {
  final OpenSettlementTransfer transfer;
  final ValueChanged<String> onStatus;
  final VoidCallback onOpenGame;

  const _SettlementRow({
    required this.transfer,
    required this.onStatus,
    required this.onOpenGame,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = Money.formatCents(transfer.amountCents);
    final headline = transfer.isOwe
        ? 'You owe ${transfer.counterpartyName}'
        : '${transfer.counterpartyName} owes you';
    final statusLabel = switch (transfer.status) {
      'paid' => 'Marked paid',
      'disputed' => 'Disputed',
      _ => 'Pending',
    };
    final statusColor = switch (transfer.status) {
      'paid' => theme.colorScheme.primary,
      'disputed' => theme.colorScheme.error,
      _ => theme.colorScheme.secondary,
    };

    final actionStyle = FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      minimumSize: const Size(0, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final action = transfer.canConfirmReceived
        ? FilledButton(
            onPressed: () => onStatus('received'),
            style: actionStyle,
            child: const Text('Confirm received'),
          )
        : transfer.canMarkPaid
        ? FilledButton.tonal(
            onPressed: () => onStatus('paid'),
            style: actionStyle,
            child: const Text('Mark paid'),
          )
        : null;

    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: InkWell(
                  onTap: onOpenGame,
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        amount,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(headline, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        transfer.gameName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      statusLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (action != null) ...[const Spacer(), action],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final Map<String, dynamic> notification;
  final VoidCallback onMarkRead;
  final VoidCallback onTap;

  const _NotificationTile({
    required this.notification,
    required this.onMarkRead,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Icon(
                Icons.notifications_outlined,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notification['title'] as String,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      notification['body'] as String,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Mark read',
                onPressed: onMarkRead,
                icon: const Icon(Icons.done),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
