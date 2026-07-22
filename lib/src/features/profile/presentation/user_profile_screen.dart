import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/profile_providers.dart';
import '../domain/profile_models.dart';
import '../../session/presentation/session_summary_screen.dart';
import '../../session/presentation/v2_game_flow_screen.dart';
import '../../help/presentation/help_screen.dart';
import 'user_history_screen.dart';

/// Screen displaying another user's mutual-game profile and statistics.
///
/// Shows:
/// - User identity
/// - Summary statistics (sessions, buy-ins, cash-outs, net profit, win rate)
/// - Recent session history
/// - Games visible through participation or a mutual group
///
/// Access to data is controlled by:
/// - Sessions the current user owns where target participated
/// - Games attached to current mutual groups
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
    _currentPlayerName =
        widget.playerName ?? widget.initialDisplayName ?? 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final params = UserProfileParams(
      userId: widget.userId,
      groupId: _selectedGroupId,
    );
    final statsAsync = ref.watch(userProfileStatsProvider(params));
    final sessionsAsync = ref.watch(userSessionsProvider(params));
    final mutualGroupsAsync = ref.watch(mutualGroupsProvider(widget.userId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_currentPlayerName, overflow: TextOverflow.ellipsis),
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
          ref.invalidate(mutualGroupsProvider(widget.userId));
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Profile header with account name, email
            _buildProfileHeader(context, statsAsync),
            const SizedBox(height: 16),

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

  Widget _buildProfileHeader(
    BuildContext context,
    AsyncValue<UserProfileStats> statsAsync,
  ) {
    final displayName =
        statsAsync.valueOrNull?.displayName ??
        widget.initialDisplayName ??
        'Unknown';
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

  Widget _buildGroupFilter(
    BuildContext context,
    AsyncValue<List<Map<String, dynamic>>> groupsAsync,
  ) {
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    value: _selectedGroupId,
                    isExpanded: true,
                    isDense: true,
                    icon: Icon(
                      Icons.keyboard_arrow_down,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    style: Theme.of(context).textTheme.bodyMedium,
                    dropdownColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    items: [
                      DropdownMenuItem<int?>(
                        value: null,
                        child: Row(
                          children: [
                            Icon(
                              Icons.bar_chart,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            const Text('All Stats'),
                          ],
                        ),
                      ),
                      ...groups.map(
                        (g) => DropdownMenuItem<int?>(
                          value: g['id'] as int,
                          child: Row(
                            children: [
                              Icon(
                                Icons.group,
                                size: 18,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                              const SizedBox(width: 8),
                              Text(g['name'] as String),
                            ],
                          ),
                        ),
                      ),
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
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Date Range',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: Colors.grey),
              ),
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
                        final picked = await _pickDate(
                          context,
                          _startDate ?? DateTime.now(),
                        );
                        if (picked != null) {
                          setState(() => _startDate = picked);
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                      onClear: _startDate != null
                          ? () {
                              setState(() => _startDate = null);
                              Navigator.pop(context);
                            }
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DateButton(
                      label: 'End Date',
                      date: _endDate,
                      onTap: () async {
                        final picked = await _pickDate(
                          context,
                          _endDate ?? DateTime.now(),
                        );
                        if (picked != null) {
                          setState(() => _endDate = picked);
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                      onClear: _endDate != null
                          ? () {
                              setState(() => _endDate = null);
                              Navigator.pop(context);
                            }
                          : null,
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
    return showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
  }

  Widget _buildFilteredContent(
    BuildContext context,
    AsyncValue<List<UserSessionSummary>> sessionsAsync,
  ) {
    return sessionsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Text('Game history could not be loaded.'),
      data: (sessions) {
        // Apply date filters
        var filteredSessions = sessions.toList();
        if (_startDate != null) {
          filteredSessions = filteredSessions
              .where((s) => !s.startedAt.isBefore(_startDate!))
              .toList();
        }
        if (_endDate != null) {
          filteredSessions = filteredSessions
              .where(
                (s) => !s.startedAt.isAfter(
                  _endDate!.add(const Duration(days: 1)),
                ),
              )
              .toList();
        }

        // Calculate stats from filtered sessions
        final totalSessions = filteredSessions.length;
        final totalBuyIns = filteredSessions.fold<int>(
          0,
          (sum, s) => sum + s.buyInsCents,
        );
        final totalCashOuts = filteredSessions.fold<int>(
          0,
          (sum, s) => sum + s.cashOutsCents,
        );
        final totalNet = totalCashOuts - totalBuyIns;
        final wins = filteredSessions.where((s) => s.netCents > 0).length;
        final winRate = totalSessions > 0 ? (wins / totalSessions * 100) : 0.0;
        final bestSession = filteredSessions.isEmpty
            ? 0
            : filteredSessions
                  .map((s) => s.netCents)
                  .reduce((a, b) => a > b ? a : b);
        final worstSession = filteredSessions.isEmpty
            ? 0
            : filteredSessions
                  .map((s) => s.netCents)
                  .reduce((a, b) => a < b ? a : b);

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
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: valueColor),
              ),
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
                  Text(
                    'Summary',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 20,
                    runSpacing: 12,
                    children: [
                      stat('Games', totalSessions.toString()),
                      stat(
                        'Total buy-ins',
                        _currency.format(totalBuyIns / 100),
                      ),
                      stat(
                        'Total cash-outs',
                        _currency.format(totalCashOuts / 100),
                      ),
                      stat(
                        'Total net',
                        _currency.format(totalNet / 100),
                        valueColor: netColor(totalNet),
                      ),
                      stat('Win rate', '${winRate.toStringAsFixed(0)}%'),
                      stat(
                        'Best session',
                        _currency.format(bestSession / 100),
                        valueColor: bestSession > 0 ? Colors.green : null,
                      ),
                      stat(
                        'Worst session',
                        _currency.format(worstSession / 100),
                        valueColor: worstSession < 0 ? Colors.red : null,
                      ),
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
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => UserHistoryScreen(
                          userId: widget.userId,
                          displayName:
                              widget.playerName ?? widget.initialDisplayName,
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
              _buildEmptyState(
                context,
                'No games yet',
                'Games will appear here.',
              )
            else
              Column(
                children: filteredSessions
                    .take(3)
                    .map((s) => _buildSessionTile(context, s))
                    .toList(),
              ),
            const SizedBox(height: 24),

            // Shared sessions section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Shared Sessions',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => UserHistoryScreen(
                          userId: widget.userId,
                          displayName:
                              widget.playerName ?? widget.initialDisplayName,
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
              _buildEmptyState(
                context,
                'No mutual-group games',
                'Games attached to a mutual group will appear here.',
              )
            else
              Column(
                children: sharedSessions
                    .take(3)
                    .map((s) => _buildSessionTile(context, s))
                    .toList(),
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
              builder: (_) => session.ledgerVersion == 2
                  ? V2GameFlowScreen(sessionId: session.sessionId)
                  : SessionSummaryScreen(sessionId: session.sessionId),
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
              Icon(
                Icons.casino_outlined,
                size: 40,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
              ),
              Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateButton extends StatelessWidget {
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  const _DateButton({
    required this.label,
    required this.date,
    required this.onTap,
    this.onClear,
  });

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
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: Colors.grey),
                ),
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
