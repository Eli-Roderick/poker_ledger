import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../../../auth/providers/auth_providers.dart';
import '../../groups/data/group_providers.dart';
import '../../session/data/sessions_list_providers.dart';
import '../../session/data/v2_game_providers.dart';
import '../../session/domain/session_models.dart';
import '../../session/presentation/game_setup_wizard.dart';
import '../../session/presentation/session_summary_screen.dart';
import '../../session/presentation/v2_game_flow_screen.dart';

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
    final sessions = ref.watch(sessionsListProvider);
    final gameInvitations = ref.watch(pendingGameInvitationsProvider);
    final groupInvitations = ref.watch(pendingGroupInvitationsProvider);
    final notifications = ref.watch(unreadNotificationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(sessionsListProvider.notifier).refresh();
          ref.invalidate(pendingGameInvitationsProvider);
          ref.invalidate(pendingGroupInvitationsProvider);
          ref.invalidate(unreadNotificationsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Poker Ledger',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const Text('Your next required action, without the guesswork.'),
            const SizedBox(height: 20),
            sessions.when(
              loading: () => const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: LinearProgressIndicator(),
                ),
              ),
              error: (_, __) => _ActionCard(
                icon: Icons.sync_problem,
                title: 'Games could not be loaded',
                subtitle: 'Open Games to retry.',
                actionLabel: 'Open Games',
                onPressed: onOpenGames,
              ),
              data: (rows) {
                final active =
                    rows.where((row) => !row.session.finalized).toList()..sort(
                      (left, right) => right.session.startedAt.compareTo(
                        left.session.startedAt,
                      ),
                    );
                if (active.isEmpty) {
                  return _ActionCard(
                    icon: Icons.add_circle_outline,
                    title: 'Start your next game',
                    subtitle:
                        'Create a private game or attach exactly one group.',
                    actionLabel: 'Open Games',
                    onPressed: onOpenGames,
                  );
                }
                final row = active.first;
                return _ActionCard(
                  icon: Icons.play_circle_outline,
                  title: row.session.name ?? 'Active poker game',
                  subtitle: _phaseLabel(row.session),
                  actionLabel: 'Continue',
                  onPressed: () => _openSession(context, row),
                );
              },
            ),
            const SizedBox(height: 12),
            gameInvitations.when(
              data: (rows) => rows.isEmpty
                  ? const SizedBox.shrink()
                  : _ActionCard(
                      icon: Icons.mark_email_unread_outlined,
                      title:
                          '${rows.length} game invitation${rows.length == 1 ? '' : 's'}',
                      subtitle:
                          'Accepting is required before a game affects stats.',
                      actionLabel: 'Review in Games',
                      onPressed: onOpenGames,
                    ),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            groupInvitations.when(
              data: (rows) => rows.isEmpty
                  ? const SizedBox.shrink()
                  : _ActionCard(
                      icon: Icons.group_add_outlined,
                      title:
                          '${rows.length} group invitation${rows.length == 1 ? '' : 's'}',
                      subtitle:
                          'Membership starts only after you accept an invite.',
                      actionLabel: 'Review Groups',
                      onPressed: onOpenGroups,
                    ),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            notifications.when(
              data: (rows) => Column(
                children: rows
                    .map(
                      (notification) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.notifications_outlined),
                          title: Text(notification['title'] as String),
                          subtitle: Text(notification['body'] as String),
                          trailing: IconButton(
                            tooltip: 'Mark read',
                            onPressed: () async {
                              await Supabase.instance.client
                                  .from('user_notifications')
                                  .update({
                                    'read_at': DateTime.now().toIso8601String(),
                                  })
                                  .eq('id', notification['id']);
                              ref.invalidate(unreadNotificationsProvider);
                            },
                            icon: const Icon(Icons.done),
                          ),
                          onTap: () async {
                            final data = notification['data'] as Map?;
                            final sessionId = data?['session_id'] as int?;
                            await Supabase.instance.client
                                .from('user_notifications')
                                .update({
                                  'read_at': DateTime.now().toIso8601String(),
                                })
                                .eq('id', notification['id']);
                            ref.invalidate(unreadNotificationsProvider);
                            if (sessionId != null && context.mounted) {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      V2GameFlowScreen(sessionId: sessionId),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                    )
                    .toList(),
              ),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  String _phaseLabel(Session session) {
    if (session.ledgerVersion == 1) return 'Legacy game · continue setup';
    return switch (session.phase) {
      'draft' => 'Draft · finish the lobby and mode checkpoint',
      'live' => 'Live · record rebuys',
      'settling' => 'Settlement ready · review and finalize',
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

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onPressed;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(subtitle),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(onPressed: onPressed, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
