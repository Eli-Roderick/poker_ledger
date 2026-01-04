import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/profile_providers.dart';
import '../domain/profile_models.dart';
import '../../session/presentation/session_summary_screen.dart';
import '../../players/data/players_providers.dart';
import '../../help/presentation/help_screen.dart';
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
  late String _currentPlayerName;

  @override
  void initState() {
    super.initState();
    _currentPlayerName = widget.playerName ?? widget.initialDisplayName ?? 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final params = UserProfileParams(userId: widget.userId, groupId: _selectedGroupId);
    final statsAsync = ref.watch(userProfileStatsProvider(params));
    final sessionsAsync = ref.watch(userSessionsProvider(params));
    final followStatusAsync = ref.watch(followStatusProvider(widget.userId));
    final mutualGroupsAsync = ref.watch(mutualGroupsProvider(widget.userId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _currentPlayerName,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.playerId != null)
              IconButton(
                icon: const Icon(Icons.edit, size: 18),
                tooltip: 'Edit name',
                onPressed: () => _showEditNameDialog(context),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => context.showHelp(HelpPage.playerProfile),
            tooltip: 'Help',
          ),
        ],
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
            // Profile header with account name, email
            _buildProfileHeader(context, statsAsync),
            const SizedBox(height: 16),

            // Follow section
            _buildFollowSection(context, followStatusAsync),
            const SizedBox(height: 16),

            // Warning about following for private stats
            _buildFollowWarning(context, followStatusAsync),

            // Group filter (only mutual groups)
            _buildGroupFilter(context, mutualGroupsAsync),
            const SizedBox(height: 24),

            // Summary stats (like old profile)
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

  Widget _buildProfileHeader(BuildContext context, AsyncValue<UserProfileStats> statsAsync) {
    final displayName = statsAsync.valueOrNull?.displayName ?? widget.initialDisplayName ?? 'Unknown';
    final email = statsAsync.valueOrNull?.email;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  if (email != null)
                    Text(
                      email,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                      overflow: TextOverflow.ellipsis,
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

  Widget _buildFollowWarning(BuildContext context, AsyncValue<Follow?> followStatusAsync) {
    return followStatusAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (follow) {
        // Only show warning if not following
        if (follow?.status == FollowStatus.accepted) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: Colors.orange.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Follow this user to see their private stats',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                  ),
                ),
              ],
            ),
          ),
        );
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
    return statsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Error: $e'),
      data: (stats) {
        Color netColor(int cents) {
          if (cents == 0) return Theme.of(context).colorScheme.outline;
          return cents > 0 ? Colors.green : Colors.red;
        }

        Widget stat(String label, String value, {Color? valueColor}) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
              const SizedBox(height: 2),
              Text(value, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: valueColor)),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Summary', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 20,
                runSpacing: 12,
                children: [
                  stat('Sessions', stats.totalSessions.toString()),
                  stat('Total buy-ins', _currency.format(stats.totalBuyInsCents / 100)),
                  stat('Total cash-outs', _currency.format(stats.totalCashOutsCents / 100)),
                  stat('Total net', _currency.format(stats.netProfitCents / 100), valueColor: netColor(stats.netProfitCents)),
                  stat('Win rate', '${stats.winRate.toStringAsFixed(0)}%'),
                  stat('Best session', _currency.format(stats.biggestWinCents / 100), valueColor: stats.biggestWinCents > 0 ? Colors.green : null),
                  stat('Worst session', _currency.format(stats.biggestLossCents / 100), valueColor: stats.biggestLossCents < 0 ? Colors.red : null),
                ],
              ),
            ],
          ),
        );
      },
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

    final controller = TextEditingController(text: _currentPlayerName);

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
      setState(() {
        _currentPlayerName = newName;
      });
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
