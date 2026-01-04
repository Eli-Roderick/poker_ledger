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
  DateTime? _startDate;
  DateTime? _endDate;
  final _currency = NumberFormat.simpleCurrency();

  @override
  void initState() {
    super.initState();
    _selectedGroupId = widget.initialGroupId;
  }

  @override
  Widget build(BuildContext context) {
    final params = UserProfileParams(userId: widget.userId, groupId: _selectedGroupId);
    final sessionsAsync = ref.watch(userSessionsProvider(params));
    final mutualGroupsAsync = ref.watch(mutualGroupsProvider(widget.userId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.showSharedOnly ? 'Shared Sessions' : 'History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Date filters',
            onPressed: () => _showDateFiltersSheet(context),
          ),
        ],
      ),
      body: sessionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (sessions) {
          // Apply all filters to get the filtered list
          var filteredSessions = sessions.toList();
          
          // Filter by shared only if needed (sessions not owned by current user)
          if (widget.showSharedOnly) {
            filteredSessions = filteredSessions.where((s) => !s.isOwner).toList();
          }
          
          // Filter by date range if set
          if (_startDate != null) {
            filteredSessions = filteredSessions.where((s) => !s.startedAt.isBefore(_startDate!)).toList();
          }
          if (_endDate != null) {
            filteredSessions = filteredSessions.where((s) => !s.startedAt.isAfter(_endDate!.add(const Duration(days: 1)))).toList();
          }
          
          // Calculate stats from filtered sessions
          final totalSessions = filteredSessions.length;
          final totalNetCents = filteredSessions.fold<int>(0, (sum, s) => sum + s.netCents);
          final wins = filteredSessions.where((s) => s.netCents > 0).length;
          final winRate = totalSessions > 0 ? (wins / totalSessions * 100) : 0.0;
          
          return Column(
            children: [
              // Group filter dropdown
              _buildGroupFilter(context, mutualGroupsAsync),
              
              // Stats summary - calculated from filtered sessions
              _buildFilteredStatsSummary(context, totalSessions, winRate, totalNetCents),
              
              // Sessions list
              Expanded(
                child: filteredSessions.isEmpty
                    ? _buildEmptyState(context)
                    : RefreshIndicator(
                        onRefresh: () async {
                          ref.invalidate(userSessionsProvider(params));
                        },
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: filteredSessions.length,
                          itemBuilder: (context, index) {
                            return _buildSessionTile(context, filteredSessions[index]);
                          },
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildGroupFilter(BuildContext context, AsyncValue<List<Map<String, dynamic>>> groupsAsync) {
    return groupsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (groups) {
        if (groups.isEmpty) return const SizedBox.shrink();
        
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Container(
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
          ),
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
                'Filters',
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

  Widget _buildFilteredStatsSummary(BuildContext context, int totalSessions, double winRate, int totalNetCents) {
    final netColor = totalNetCents == 0
        ? Theme.of(context).colorScheme.outline
        : (totalNetCents > 0 ? Colors.green : Colors.red);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildMiniStat(context, 'Sessions', totalSessions.toString()),
          _buildMiniStat(context, 'Win Rate', '${winRate.toStringAsFixed(0)}%'),
          _buildMiniStat(
            context,
            'Net',
            _currency.format(totalNetCents / 100),
            valueColor: netColor,
          ),
        ],
      ),
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
