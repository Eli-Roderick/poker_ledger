import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/profile_providers.dart';
import '../domain/profile_models.dart';
import '../../session/presentation/session_summary_screen.dart';

class UserProfileScreen extends ConsumerStatefulWidget {
  final String userId;
  final String? initialDisplayName;
  final int? playerId; // If viewing from players list, we have the player ID for nickname editing

  const UserProfileScreen({
    super.key,
    required this.userId,
    this.initialDisplayName,
    this.playerId,
  });

  @override
  ConsumerState<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends ConsumerState<UserProfileScreen> {
  int? _selectedGroupId;
  final _currency = NumberFormat.simpleCurrency();

  @override
  Widget build(BuildContext context) {
    final params = UserProfileParams(userId: widget.userId, groupId: _selectedGroupId);
    final statsAsync = ref.watch(userProfileStatsProvider(params));
    final sessionsAsync = ref.watch(userSessionsProvider(params));
    final followStatusAsync = ref.watch(followStatusProvider(widget.userId));
    final groupsAsync = ref.watch(accessibleGroupsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initialDisplayName ?? 'Profile'),
        actions: [
          if (widget.playerId != null)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit nickname',
              onPressed: () => _showNicknameDialog(context),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(userProfileStatsProvider(params));
          ref.invalidate(userSessionsProvider(params));
          ref.invalidate(followStatusProvider(widget.userId));
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Profile header
            _buildProfileHeader(context, statsAsync),
            const SizedBox(height: 16),

            // Follow button
            _buildFollowSection(context, followStatusAsync),
            const SizedBox(height: 24),

            // Group filter
            _buildGroupFilter(context, groupsAsync),
            const SizedBox(height: 16),

            // Stats cards
            statsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Error loading stats: $e'),
              data: (stats) => _buildStatsCards(context, stats),
            ),
            const SizedBox(height: 24),

            // Sessions list
            Text(
              'Sessions',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            sessionsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Error loading sessions: $e'),
              data: (sessions) => _buildSessionsList(context, sessions),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileHeader(BuildContext context, AsyncValue<UserProfileStats> statsAsync) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                Icons.person,
                size: 40,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    statsAsync.valueOrNull?.displayName ?? widget.initialDisplayName ?? 'Unknown',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  if (statsAsync.valueOrNull?.email != null)
                    Text(
                      statsAsync.valueOrNull!.email!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFollowSection(BuildContext context, AsyncValue<Follow?> followStatusAsync) {
    return followStatusAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (follow) {
        if (follow == null) {
          // Not following - show follow button
          return FilledButton.icon(
            onPressed: () => _sendFollowRequest(context),
            icon: const Icon(Icons.person_add),
            label: const Text('Request to Follow'),
          );
        }

        switch (follow.status) {
          case FollowStatus.pending:
            return OutlinedButton.icon(
              onPressed: () => _cancelFollowRequest(context),
              icon: const Icon(Icons.hourglass_empty),
              label: const Text('Request Pending'),
            );
          case FollowStatus.accepted:
            return Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 20),
                const SizedBox(width: 8),
                const Text('Following'),
                const Spacer(),
                TextButton(
                  onPressed: () => _unfollowUser(context),
                  child: const Text('Unfollow'),
                ),
              ],
            );
          case FollowStatus.rejected:
            return OutlinedButton.icon(
              onPressed: () => _sendFollowRequest(context),
              icon: const Icon(Icons.person_add),
              label: const Text('Request Again'),
            );
        }
      },
    );
  }

  Widget _buildGroupFilter(BuildContext context, AsyncValue<List<Map<String, dynamic>>> groupsAsync) {
    return groupsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (groups) {
        if (groups.isEmpty) return const SizedBox.shrink();

        return Row(
          children: [
            Text('Filter by group:', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int?>(
                value: _selectedGroupId,
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('All shared sessions')),
                  ...groups.map((g) => DropdownMenuItem<int?>(
                        value: g['id'] as int,
                        child: Text(g['name'] as String),
                      )),
                ],
                onChanged: (value) {
                  setState(() => _selectedGroupId = value);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatsCards(BuildContext context, UserProfileStats stats) {
    final netColor = stats.netProfitCents == 0
        ? Theme.of(context).colorScheme.outline
        : (stats.netProfitCents > 0 ? Colors.green : Colors.red);

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Sessions',
                value: stats.totalSessions.toString(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Win Rate',
                value: '${stats.winRate.toStringAsFixed(0)}%',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Total Buy-ins',
                value: _currency.format(stats.totalBuyInsCents / 100),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Total Cash-outs',
                value: _currency.format(stats.totalCashOutsCents / 100),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _StatCard(
          label: 'Net Profit/Loss',
          value: _currency.format(stats.netProfitCents / 100),
          valueColor: netColor,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Biggest Win',
                value: _currency.format(stats.biggestWinCents / 100),
                valueColor: stats.biggestWinCents > 0 ? Colors.green : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Biggest Loss',
                value: _currency.format(stats.biggestLossCents / 100),
                valueColor: stats.biggestLossCents < 0 ? Colors.red : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSessionsList(BuildContext context, List<UserSessionSummary> sessions) {
    if (sessions.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              children: [
                Icon(Icons.casino_outlined, size: 48, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                Text(
                  'No shared sessions',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                ),
                const SizedBox(height: 4),
                Text(
                  'Sessions will appear here when you share games with this user.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      children: sessions.map((session) {
        final netColor = session.netCents == 0
            ? Theme.of(context).colorScheme.outline
            : (session.netCents > 0 ? Colors.green : Colors.red);

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            title: Text(session.sessionName ?? 'Session #${session.sessionId}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(DateFormat.yMMMd().add_jm().format(session.startedAt)),
                if (session.groupName != null)
                  Text('Group: ${session.groupName}', style: const TextStyle(fontSize: 12)),
              ],
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _currency.format(session.netCents / 100),
                  style: TextStyle(fontWeight: FontWeight.bold, color: netColor),
                ),
                Text(
                  session.finalized ? 'Finalized' : 'In progress',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SessionSummaryScreen(sessionId: session.sessionId),
                ),
              );
            },
          ),
        );
      }).toList(),
    );
  }

  Future<void> _showNicknameDialog(BuildContext context) async {
    if (widget.playerId == null) return;

    final repo = ref.read(profileRepositoryProvider);
    final currentNickname = await repo.getNickname(widget.playerId!);
    final controller = TextEditingController(text: currentNickname ?? widget.initialDisplayName);

    if (!mounted) return;

    final newNickname = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Nickname'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Nickname',
            hintText: 'Enter a custom name for this player',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (currentNickname != null)
            TextButton(
              onPressed: () async {
                await repo.removeNickname(widget.playerId!);
                ref.invalidate(nicknamesProvider);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Remove'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newNickname != null && newNickname.isNotEmpty) {
      await repo.setNickname(widget.playerId!, newNickname);
      ref.invalidate(nicknamesProvider);
    }
  }

  Future<void> _sendFollowRequest(BuildContext context) async {
    try {
      final repo = ref.read(profileRepositoryProvider);
      await repo.sendFollowRequest(widget.userId);
      ref.invalidate(followStatusProvider(widget.userId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Follow request sent')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _cancelFollowRequest(BuildContext context) async {
    try {
      final repo = ref.read(profileRepositoryProvider);
      await repo.cancelFollow(widget.userId);
      ref.invalidate(followStatusProvider(widget.userId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Follow request cancelled')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _unfollowUser(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unfollow?'),
        content: const Text('You will no longer see their private stats.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unfollow'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final repo = ref.read(profileRepositoryProvider);
        await repo.cancelFollow(widget.userId);
        ref.invalidate(followStatusProvider(widget.userId));
        ref.invalidate(userProfileStatsProvider(UserProfileParams(userId: widget.userId, groupId: _selectedGroupId)));
        ref.invalidate(userSessionsProvider(UserProfileParams(userId: widget.userId, groupId: _selectedGroupId)));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    }
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatCard({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: valueColor,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
