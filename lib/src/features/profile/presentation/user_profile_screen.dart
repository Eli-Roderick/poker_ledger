import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/profile_providers.dart';
import '../domain/profile_models.dart';
import '../../session/presentation/session_summary_screen.dart';
import '../../players/data/players_providers.dart';
import 'user_history_screen.dart';

class UserProfileScreen extends ConsumerStatefulWidget {
  final String userId;
  final String? initialDisplayName;
  final int? playerId;
  final String? playerName;

  const UserProfileScreen({
    super.key,
    required this.userId,
    this.initialDisplayName,
    this.playerId,
    this.playerName,
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
    final mutualGroupsAsync = ref.watch(mutualGroupsProvider(widget.userId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(userProfileStatsProvider(params));
          ref.invalidate(userSessionsProvider(params));
          ref.invalidate(followStatusProvider(widget.userId));
          ref.invalidate(mutualGroupsProvider(widget.userId));
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Profile header with name, email, edit button, and follow button
            _buildProfileHeader(context, statsAsync, followStatusAsync),
            const SizedBox(height: 16),

            // Group filter (only mutual groups)
            _buildGroupFilter(context, mutualGroupsAsync),
            const SizedBox(height: 24),

            // Summary stats
            _buildSummarySection(context, statsAsync),
            const SizedBox(height: 24),

            // History section (last 3 sessions)
            _buildHistorySection(context, sessionsAsync),
            const SizedBox(height: 24),

            // Shared sessions section
            _buildSharedSessionsSection(context, sessionsAsync),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileHeader(
    BuildContext context,
    AsyncValue<UserProfileStats> statsAsync,
    AsyncValue<Follow?> followStatusAsync,
  ) {
    final displayName = statsAsync.valueOrNull?.displayName ?? widget.initialDisplayName ?? 'Unknown';
    final email = statsAsync.valueOrNull?.email;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar
                CircleAvatar(
                  radius: 32,
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(
                    Icons.person,
                    size: 32,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 16),
                // Name and email
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.playerName ?? displayName,
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                          ),
                          if (widget.playerId != null)
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              tooltip: 'Edit name',
                              onPressed: () => _showEditNameDialog(context),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                      if (email != null)
                        Text(
                          email,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                    ],
                  ),
                ),
                // Follow button
                _buildFollowButton(context, followStatusAsync),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFollowButton(BuildContext context, AsyncValue<Follow?> followStatusAsync) {
    return followStatusAsync.when(
      loading: () => const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (follow) {
        if (follow == null) {
          return IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Request to follow',
            onPressed: () => _sendFollowRequest(context),
          );
        }

        switch (follow.status) {
          case FollowStatus.pending:
            return IconButton(
              icon: const Icon(Icons.hourglass_empty),
              tooltip: 'Request pending',
              onPressed: () => _cancelFollowRequest(context),
            );
          case FollowStatus.accepted:
            return IconButton(
              icon: const Icon(Icons.check_circle, color: Colors.green),
              tooltip: 'Following - tap to unfollow',
              onPressed: () => _unfollowUser(context),
            );
          case FollowStatus.rejected:
            return IconButton(
              icon: const Icon(Icons.person_add),
              tooltip: 'Request again',
              onPressed: () => _sendFollowRequest(context),
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

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.filter_list, size: 20, color: Theme.of(context).colorScheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    value: _selectedGroupId,
                    isExpanded: true,
                    isDense: true,
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('All mutual groups')),
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
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSummarySection(BuildContext context, AsyncValue<UserProfileStats> statsAsync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Summary',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        statsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error: $e'),
          data: (stats) {
            final netColor = stats.netProfitCents == 0
                ? Theme.of(context).colorScheme.outline
                : (stats.netProfitCents > 0 ? Colors.green : Colors.red);

            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Net profit/loss - prominent
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _currency.format(stats.netProfitCents / 100),
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: netColor,
                              ),
                        ),
                      ],
                    ),
                    Text(
                      'Net Profit/Loss',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                    ),
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 12),
                    // Stats grid
                    Row(
                      children: [
                        _buildStatItem(context, 'Sessions', stats.totalSessions.toString()),
                        _buildStatItem(context, 'Win Rate', '${stats.winRate.toStringAsFixed(0)}%'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _buildStatItem(context, 'Buy-ins', _currency.format(stats.totalBuyInsCents / 100)),
                        _buildStatItem(context, 'Cash-outs', _currency.format(stats.totalCashOutsCents / 100)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _buildStatItem(
                          context,
                          'Best Session',
                          _currency.format(stats.biggestWinCents / 100),
                          valueColor: stats.biggestWinCents > 0 ? Colors.green : null,
                        ),
                        _buildStatItem(
                          context,
                          'Worst Session',
                          _currency.format(stats.biggestLossCents / 100),
                          valueColor: stats.biggestLossCents < 0 ? Colors.red : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildStatItem(BuildContext context, String label, String value, {Color? valueColor}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: valueColor,
                ),
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistorySection(BuildContext context, AsyncValue<List<UserSessionSummary>> sessionsAsync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'History',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => UserHistoryScreen(
                      userId: widget.userId,
                      displayName: widget.playerName ?? widget.initialDisplayName,
                      initialGroupId: _selectedGroupId,
                    ),
                  ),
                );
              },
              child: const Text('View All'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        sessionsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error: $e'),
          data: (sessions) {
            if (sessions.isEmpty) {
              return _buildEmptyState(context, 'No sessions yet', 'Sessions will appear here.');
            }
            // Show only last 3 sessions
            final recentSessions = sessions.take(3).toList();
            return Column(
              children: recentSessions.map((s) => _buildSessionTile(context, s)).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSharedSessionsSection(BuildContext context, AsyncValue<List<UserSessionSummary>> sessionsAsync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Shared Sessions',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => UserHistoryScreen(
                      userId: widget.userId,
                      displayName: widget.playerName ?? widget.initialDisplayName,
                      initialGroupId: _selectedGroupId,
                      showSharedOnly: true,
                    ),
                  ),
                );
              },
              child: const Text('View All'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Sessions you\'ve played together',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
        const SizedBox(height: 8),
        sessionsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error: $e'),
          data: (sessions) {
            // Filter to sessions where both users participated (shared sessions)
            final sharedSessions = sessions.where((s) => s.groupId != null).take(3).toList();
            if (sharedSessions.isEmpty) {
              return _buildEmptyState(
                context,
                'No shared sessions',
                'Sessions shared to mutual groups will appear here.',
              );
            }
            return Column(
              children: sharedSessions.map((s) => _buildSessionTile(context, s)).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSessionTile(BuildContext context, UserSessionSummary session) {
    final netColor = session.netCents == 0
        ? Theme.of(context).colorScheme.outline
        : (session.netCents > 0 ? Colors.green : Colors.red);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(session.sessionName ?? 'Session #${session.sessionId}'),
        subtitle: Text(DateFormat.yMMMd().format(session.startedAt)),
        trailing: Text(
          _currency.format(session.netCents / 100),
          style: TextStyle(fontWeight: FontWeight.bold, color: netColor),
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
  }

  Widget _buildEmptyState(BuildContext context, String title, String subtitle) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.casino_outlined, size: 40, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              Text(title, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey)),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showEditNameDialog(BuildContext context) async {
    if (widget.playerId == null) return;

    final controller = TextEditingController(text: widget.playerName ?? widget.initialDisplayName);

    final newName = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Player Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Enter name for this player',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && mounted) {
      await ref.read(playersListProvider.notifier).updatePlayer(
            id: widget.playerId!,
            name: newName,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Name updated')),
        );
      }
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
