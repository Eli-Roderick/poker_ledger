import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_providers.dart';
import '../../features/profile/data/profile_providers.dart';
import '../../features/help/presentation/help_screen.dart';
import '../../features/session/data/sessions_list_providers.dart';
import '../../features/session/data/v2_game_providers.dart';
import '../../features/session/presentation/game_invitations_sheet.dart';
import '../../features/session/presentation/join_accepted_buy_in_dialog.dart';
import '../../utils/money.dart';
import 'settings_screen.dart';

final currentProfileDetailsProvider = FutureProvider<Map<String, dynamic>?>((
  ref,
) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  return ref.read(profileRepositoryProvider).getUserProfile(user.id);
});

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = Supabase.instance.client.auth.currentUser;
    final profileAsync = ref.watch(currentProfileDetailsProvider);
    final statsAsync = user == null
        ? null
        : ref.watch(
            userProfileStatsProvider(UserProfileParams(userId: user.id)),
          );
    final profile = profileAsync.valueOrNull;
    final pendingInviteCount =
        ref.watch(pendingGameInvitationsProvider).valueOrNull?.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.help_outline),
          onPressed: () => context.showHelp(HelpPage.profile),
          tooltip: 'Help',
        ),
        title: const Text('Profile'),
        actions: [
          IconButton(
            tooltip: 'Game invitations',
            onPressed: () => _showPendingInvitations(context, ref),
            icon: Badge(
              isLabelVisible: pendingInviteCount > 0,
              label: Text('$pendingInviteCount'),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: CircleAvatar(
              radius: 50,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                Icons.person,
                size: 50,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Account Information',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _InfoRow(
                    icon: Icons.person_outline,
                    label: 'Display Name',
                    value: profile?['display_name'] as String? ?? 'Not set',
                  ),
                  const Divider(),
                  _InfoRow(
                    icon: Icons.alternate_email,
                    label: 'Handle',
                    value: profile?['handle'] == null
                        ? 'Not set'
                        : '@${profile!['handle']}',
                  ),
                  const Divider(),
                  _InfoRow(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: user?.email ?? 'Not set',
                  ),
                  const Divider(),
                  _InfoRow(
                    icon: Icons.calendar_today_outlined,
                    label: 'Member Since',
                    value: user?.createdAt != null
                        ? _formatDate(DateTime.parse(user!.createdAt))
                        : 'Unknown',
                  ),
                ],
              ),
            ),
          ),
          Text(
            'Personal stats',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (statsAsync != null)
            statsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const Card(
                child: ListTile(
                  leading: Icon(Icons.sync_problem),
                  title: Text('Stats could not be loaded'),
                ),
              ),
              data: (stats) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: _StatValue(
                          label: 'Games',
                          value: '${stats.totalSessions}',
                        ),
                      ),
                      Expanded(
                        child: _StatValue(
                          label: 'Net',
                          value: Money.formatCents(
                            stats.netProfitCents,
                            symbol: '\$',
                          ),
                        ),
                      ),
                      Expanded(
                        child: _StatValue(
                          label: 'Win rate',
                          value: '${stats.winRate.toStringAsFixed(0)}%',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          const Text(
            'Every finalized game you accepted counts here. Hosted and joined '
            'game history is available under Games.',
          ),
          const SizedBox(height: 32),
          OutlinedButton.icon(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Sign Out'),
                  content: const Text('Are you sure you want to sign out?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Sign Out'),
                    ),
                  ],
                ),
              );

              if (confirmed == true) {
                await ref.read(authRepositoryProvider).signOut();
                // Invalidate providers to ensure clean state
                ref.invalidate(authStateProvider);
              }
            },
            icon: const Icon(Icons.logout),
            label: const Text('Sign Out'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: const BorderSide(color: Colors.red),
              padding: const EdgeInsets.all(16),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}

Future<void> _showPendingInvitations(
  BuildContext context,
  WidgetRef ref,
) async {
  await showPendingInviteeInvitationsSheet(
    context: context,
    ref: ref,
    onAccepted: (invitation) async {
      ref.read(sessionsListProvider.notifier).refresh();
      if (!context.mounted) return;
      await showJoinAcceptedBuyInDialog(
        context: context,
        ref: ref,
        sessionId: invitation.sessionId,
        invitationId: invitation.id,
      );
    },
  );
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              Text(value, style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatValue extends StatelessWidget {
  final String label;
  final String value;

  const _StatValue({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
