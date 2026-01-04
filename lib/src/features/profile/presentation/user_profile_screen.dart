import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/profile_providers.dart';
import '../domain/profile_models.dart';
import '../../session/presentation/session_summary_screen.dart';
import '../../players/data/players_providers.dart';
import '../../help/presentation/help_screen.dart';
import 'user_history_screen.dart';

/// Screen displaying another user's poker profile and statistics.
/// 
/// Shows:
/// - User info (display name, email, follow status)
/// - Summary statistics (sessions, buy-ins, cash-outs, net profit, win rate)
/// - Recent session history
/// - Shared sessions (sessions where both users participated)
/// 
/// Access to data is controlled by:
/// - Sessions the current user owns where target participated
/// - Sessions shared to mutual groups
/// - All sessions if current user follows the target (accepted)
/// 
/// The [playerId] and [playerName] are optional and used when navigating
/// from the Players list to show the local player name context.
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
  DateTime? _startDate;
  DateTime? _endDate;
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

            // Summary stats and history - computed from filtered sessions
            _buildFilteredContent(context, sessionsAsync),
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
    final hasDateFilter = _startDate != null || _endDate != null;
    
    return groupsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (groups) {
        return Row(
          children: [
            // Group dropdown in its own styled container
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    value: _selectedGroupId,
                    isExpanded: true,
                    isDense: true,
                    icon: Icon(Icons.keyboard_arrow_down, color: Theme.of(context).colorScheme.outline),
                    style: Theme.of(context).textTheme.bodyMedium,
                    dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    items: [
                      DropdownMenuItem<int?>(
                        value: null,
                        child: Row(
                          children: [
                            Icon(Icons.bar_chart, size: 18, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            const Text('All Stats'),
                          ],
                        ),
                      ),
                      ...groups.map((g) => DropdownMenuItem<int?>(
                            value: g['id'] as int,
                            child: Row(
                              children: [
                                Icon(Icons.group, size: 18, color: Theme.of(context).colorScheme.outline),
                                const SizedBox(width: 8),
                                Text(g['name'] as String),
                              ],
                            ),
                          )),
                    ],
                    onChanged: (value) {
                      setState(() => _selectedGroupId = value);
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Filter icon in its own bubble - match height with dropdown
            Container(
              height: 48, // Match dropdown height
              width: 48,
              decoration: BoxDecoration(
                color: hasDateFilter 
                    ? Theme.of(context).colorScheme.primaryContainer 
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: IconButton(
                icon: Icon(
                  hasDateFilter ? Icons.filter_alt : Icons.filter_list,
                  color: hasDateFilter 
                      ? Theme.of(context).colorScheme.primary 
                      : Theme.of(context).colorScheme.outline,
                ),
                tooltip: 'Date filters',
                onPressed: () => _showDateFiltersSheet(context),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showDateFiltersSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Date Filters',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Date Range', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.grey)),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: _DateButton(
                      label: 'Start Date',
                      date: _startDate,
                      onTap: () async {
                        final picked = await _pickDate(context, _startDate ?? DateTime.now());
                        if (picked != null) {
                          setState(() => _startDate = picked);
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                      onClear: _startDate != null ? () {
                        setState(() => _startDate = null);
                        Navigator.pop(context);
                      } : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DateButton(
                      label: 'End Date',
                      date: _endDate,
                      onTap: () async {
                        final picked = await _pickDate(context, _endDate ?? DateTime.now());
                        if (picked != null) {
                          setState(() => _endDate = picked);
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                      onClear: _endDate != null ? () {
                        setState(() => _endDate = null);
                        Navigator.pop(context);
                      } : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.tonal(
                onPressed: () {
                  setState(() {
                    _startDate = null;
                    _endDate = null;
                  });
                  Navigator.pop(context);
                },
                child: const Text('Clear All Filters'),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<DateTime?> _pickDate(BuildContext context, DateTime initial) async {
    final now = DateTime.now();
    final first = DateTime(now.year - 5);
    final last = DateTime(now.year + 5);
    return showDatePicker(context: context, initialDate: initial, firstDate: first, lastDate: last);
  }

  Widget _buildFilteredContent(BuildContext context, AsyncValue<List<UserSessionSummary>> sessionsAsync) {
    return sessionsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Error: $e'),
      data: (sessions) {
        // Apply date filters
        var filteredSessions = sessions.toList();
        if (_startDate != null) {
          filteredSessions = filteredSessions.where((s) => !s.startedAt.isBefore(_startDate!)).toList();
        }
        if (_endDate != null) {
          filteredSessions = filteredSessions.where((s) => !s.startedAt.isAfter(_endDate!.add(const Duration(days: 1)))).toList();
        }

        // Calculate stats from filtered sessions
        final totalSessions = filteredSessions.length;
        final totalBuyIns = filteredSessions.fold<int>(0, (sum, s) => sum + s.buyInsCents);
        final totalCashOuts = filteredSessions.fold<int>(0, (sum, s) => sum + s.cashOutsCents);
        final totalNet = totalCashOuts - totalBuyIns;
        final wins = filteredSessions.where((s) => s.netCents > 0).length;
        final winRate = totalSessions > 0 ? (wins / totalSessions * 100) : 0.0;
        final bestSession = filteredSessions.isEmpty ? 0 : filteredSessions.map((s) => s.netCents).reduce((a, b) => a > b ? a : b);
        final worstSession = filteredSessions.isEmpty ? 0 : filteredSessions.map((s) => s.netCents).reduce((a, b) => a < b ? a : b);

        // Shared sessions - all sessions where both users participated together
        // This includes sessions owned by current user where target participated
        final sharedSessions = filteredSessions;

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

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Summary section
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Summary', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 20,
                    runSpacing: 12,
                    children: [
                      stat('Games', totalSessions.toString()),
                      stat('Total buy-ins', _currency.format(totalBuyIns / 100)),
                      stat('Total cash-outs', _currency.format(totalCashOuts / 100)),
                      stat('Total net', _currency.format(totalNet / 100), valueColor: netColor(totalNet)),
                      stat('Win rate', '${winRate.toStringAsFixed(0)}%'),
                      stat('Best session', _currency.format(bestSession / 100), valueColor: bestSession > 0 ? Colors.green : null),
                      stat('Worst session', _currency.format(worstSession / 100), valueColor: worstSession < 0 ? Colors.red : null),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // History section
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
            if (filteredSessions.isEmpty)
              _buildEmptyState(context, 'No games yet', 'Games will appear here.')
            else
              Column(
                children: filteredSessions.take(3).map((s) => _buildSessionTile(context, s)).toList(),
              ),
            const SizedBox(height: 24),

            // Shared sessions section
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
            if (sharedSessions.isEmpty)
              _buildEmptyState(context, 'No shared games', 'Games shared to groups will appear here.')
            else
              Column(
                children: sharedSessions.take(3).map((s) => _buildSessionTile(context, s)).toList(),
              ),
          ],
        );
      },
    );
  }

  Widget _buildSessionTile(BuildContext context, UserSessionSummary session) {
    final netColor = session.netCents == 0
        ? Theme.of(context).colorScheme.outline
        : (session.netCents > 0 ? Colors.green : Colors.red);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(session.sessionName ?? 'Game #${session.sessionId}'),
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
      // Also refresh sessions since follow status affects what's visible
      ref.invalidate(userSessionsProvider(UserProfileParams(userId: widget.userId, groupId: _selectedGroupId)));
      ref.invalidate(userProfileStatsProvider(UserProfileParams(userId: widget.userId, groupId: _selectedGroupId)));
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
      // Also refresh sessions since follow status affects what's visible
      ref.invalidate(userSessionsProvider(UserProfileParams(userId: widget.userId, groupId: _selectedGroupId)));
      ref.invalidate(userProfileStatsProvider(UserProfileParams(userId: widget.userId, groupId: _selectedGroupId)));
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

class _DateButton extends StatelessWidget {
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  const _DateButton({required this.label, required this.date, required this.onTap, this.onClear});

  @override
  Widget build(BuildContext context) {
    final text = date == null ? 'Any' : DateFormat.yMMMd().format(date!);
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.grey)),
                const SizedBox(height: 2),
                Text(text, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
          if (onClear != null)
            GestureDetector(
              onTap: onClear,
              child: const Icon(Icons.close, size: 18),
            )
          else
            const Icon(Icons.calendar_today, size: 18),
        ],
      ),
    );
  }
}
