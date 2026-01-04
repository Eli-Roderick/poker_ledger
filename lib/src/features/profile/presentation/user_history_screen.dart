import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/profile_providers.dart';
import '../domain/profile_models.dart';
import '../../session/presentation/session_summary_screen.dart';

class UserHistoryScreen extends ConsumerStatefulWidget {
  final String userId;
  final String? displayName;
  final int? initialGroupId;
  final bool showSharedOnly;

  const UserHistoryScreen({
    super.key,
    required this.userId,
    this.displayName,
    this.initialGroupId,
    this.showSharedOnly = false,
  });

  @override
  ConsumerState<UserHistoryScreen> createState() => _UserHistoryScreenState();
}

class _UserHistoryScreenState extends ConsumerState<UserHistoryScreen> {
  int? _selectedGroupId;
  DateTimeRange? _dateRange;
  final _currency = NumberFormat.simpleCurrency();

  @override
  void initState() {
    super.initState();
    _selectedGroupId = widget.initialGroupId;
  }

  @override
  Widget build(BuildContext context) {
    final params = UserProfileParams(userId: widget.userId, groupId: _selectedGroupId);
    final statsAsync = ref.watch(userProfileStatsProvider(params));
    final sessionsAsync = ref.watch(userSessionsProvider(params));
    final mutualGroupsAsync = ref.watch(mutualGroupsProvider(widget.userId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.showSharedOnly ? 'Shared Sessions' : 'History'),
      ),
      body: Column(
        children: [
          // Filters section
          _buildFiltersSection(context, mutualGroupsAsync),
          
          // Stats summary
          _buildStatsSummary(context, statsAsync),
          
          // Sessions list
          Expanded(
            child: sessionsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (sessions) {
                var filteredSessions = sessions;
                
                // Filter by shared only if needed
                if (widget.showSharedOnly) {
                  filteredSessions = filteredSessions.where((s) => s.groupId != null).toList();
                }
                
                // Filter by date range if set
                if (_dateRange != null) {
                  filteredSessions = filteredSessions.where((s) {
                    return !s.startedAt.isBefore(_dateRange!.start) &&
                           !s.startedAt.isAfter(_dateRange!.end.add(const Duration(days: 1)));
                  }).toList();
                }
                
                if (filteredSessions.isEmpty) {
                  return _buildEmptyState(context);
                }
                
                return RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(userSessionsProvider(params));
                    ref.invalidate(userProfileStatsProvider(params));
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filteredSessions.length,
                    itemBuilder: (context, index) {
                      return _buildSessionTile(context, filteredSessions[index]);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFiltersSection(BuildContext context, AsyncValue<List<Map<String, dynamic>>> groupsAsync) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Group filter
          groupsAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (groups) {
              if (groups.isEmpty) return const SizedBox.shrink();
              
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    value: _selectedGroupId,
                    isExpanded: true,
                    isDense: true,
                    hint: const Text('All mutual groups'),
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
              );
            },
          ),
          const SizedBox(height: 12),
          
          // Date range filter
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.date_range, size: 18),
                  label: Text(
                    _dateRange == null
                        ? 'All time'
                        : '${DateFormat.MMMd().format(_dateRange!.start)} - ${DateFormat.MMMd().format(_dateRange!.end)}',
                  ),
                  onPressed: () => _selectDateRange(context),
                ),
              ),
              if (_dateRange != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear date filter',
                  onPressed: () {
                    setState(() => _dateRange = null);
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatsSummary(BuildContext context, AsyncValue<UserProfileStats> statsAsync) {
    return statsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (stats) {
        final netColor = stats.netProfitCents == 0
            ? Theme.of(context).colorScheme.outline
            : (stats.netProfitCents > 0 ? Colors.green : Colors.red);

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildMiniStat(context, 'Sessions', stats.totalSessions.toString()),
              _buildMiniStat(context, 'Win Rate', '${stats.winRate.toStringAsFixed(0)}%'),
              _buildMiniStat(
                context,
                'Net',
                _currency.format(stats.netProfitCents / 100),
                valueColor: netColor,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMiniStat(BuildContext context, String label, String value, {Color? valueColor}) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
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
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(DateFormat.yMMMd().add_jm().format(session.startedAt)),
            if (session.groupName != null)
              Text(
                session.groupName!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _currency.format(session.netCents / 100),
              style: TextStyle(fontWeight: FontWeight.bold, color: netColor, fontSize: 16),
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
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.casino_outlined, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              widget.showSharedOnly ? 'No shared sessions' : 'No sessions found',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text(
              widget.showSharedOnly
                  ? 'Sessions shared to mutual groups will appear here.'
                  : 'Try adjusting your filters.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectDateRange(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: _dateRange ?? DateTimeRange(
        start: now.subtract(const Duration(days: 30)),
        end: now,
      ),
    );
    
    if (picked != null) {
      setState(() => _dateRange = picked);
    }
  }
}
