import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../../session/domain/session_models.dart';
import '../../groups/data/group_providers.dart';
import '../../groups/domain/group_models.dart';

import '../data/analytics_providers.dart';
import '../../players/presentation/player_detail_screen.dart';

class AnalyticsScreen extends ConsumerWidget {
  static const routeName = '/analytics';
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(analyticsProvider);
    final currency = NumberFormat.simpleCurrency();

    final groupsAsync = ref.watch(myGroupsProvider);
    final currentFilters = async.valueOrNull?.filters;
    final groupLabel = currentFilters?.groupName ?? 'All Sessions';
    
    return Scaffold(
      appBar: AppBar(
        title: PopupMenuButton<dynamic>(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(groupLabel),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
          onSelected: (value) {
            if (value == 'all') {
              ref.read(analyticsProvider.notifier).setFilters(
                (currentFilters ?? const AnalyticsFilters()).clearGroup(),
              );
            } else if (value is Group) {
              ref.read(analyticsProvider.notifier).setFilters(
                (currentFilters ?? const AnalyticsFilters()).copyWith(
                  groupId: value.id,
                  groupName: value.name,
                ),
              );
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'all', child: Text('All Sessions')),
            const PopupMenuDivider(),
            ...groupsAsync.when(
              loading: () => [const PopupMenuItem(enabled: false, child: Text('Loading...'))],
              error: (_, __) => <PopupMenuEntry<dynamic>>[],
              data: (groups) => groups.map((g) => PopupMenuItem<Group>(value: g, child: Text(g.name))).toList(),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Filters',
            icon: const Icon(Icons.filter_list),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                showDragHandle: true,
                builder: (_) {
                  return Consumer(
                    builder: (context, ref, __) {
                      final current = ref.watch(analyticsProvider);
                      final state = current.valueOrNull;
                      if (state == null) {
                        return const Padding(
                          padding: EdgeInsets.all(16.0),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: _AnalyticsFiltersBar(
                          filters: state.filters,
                          onChanged: (f) => ref.read(analyticsProvider.notifier).setFilters(f),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.download_outlined),
            onPressed: () async {
              final current = ref.read(analyticsProvider);
              final state = current.valueOrNull;
              if (state == null) return;
              await _exportAnalyticsCsv(state);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Analytics CSV exported')));
              }
            },
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (state) {
          return CustomScrollView(
            slivers: [
              // Filters moved to AppBar bottom sheet
              SliverPadding(
                padding: const EdgeInsets.all(8),
                sliver: SliverToBoxAdapter(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          Expanded(child: _KpiChip(label: 'Sessions', value: state.totalSessions.toString())),
                          const SizedBox(width: 8),
                          Expanded(child: _KpiChip(label: 'Unique players', value: state.totalPlayersSeen.toString())),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _KpiChip(
                              label: 'Net total',
                              value: currency.format(state.globalNetCents / 100),
                              valueColor: state.globalNetCents == 0
                                  ? Theme.of(context).colorScheme.outline
                                  : (state.globalNetCents > 0 ? Colors.green : Colors.red),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
                  child: Row(
                    children: [
                      Text('Top Players', style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      TextButton(
                        onPressed: () => _showAllPlayersSheet(context, state),
                        child: const Text('View all'),
                      ),
                    ],
                  ),
                ),
              ),
              SliverList.separated(
                itemBuilder: (_, i) {
                  final activeTop = state.players.where((p) => p.active).toList();
                  final p = activeTop[i];
                  return _PlayerTile(p: p, currency: currency);
                },
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemCount: () {
                  final activeCount = state.players.where((p) => p.active).length;
                  return activeCount >= 3 ? 3 : activeCount;
                }(),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
                  child: Text('Sessions', style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
              SliverList.separated(
                itemCount: state.sessions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final s = state.sessions[i];
                  final subtitle = _formatSessionSubtitle(s.session);
                  return ListTile(
                    dense: true,
                    title: Text('Session #${s.session.id ?? '-'}'),
                    subtitle: Text(subtitle),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('Players: ${s.players}'),
                        Text('Net: ${currency.format(s.netCents / 100)}',
                            style: TextStyle(color: s.netCents == 0 ? Theme.of(context).colorScheme.outline : (s.netCents > 0 ? Colors.green : Colors.red))),
                      ],
                    ),
                  );
                },
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
            ],
          );
        },
      ),
    );
  }

  String _formatSessionSubtitle(Session s) {
    final start = DateFormat.yMMMd().add_jm().format(s.startedAt);
    final status = s.finalized ? 'Finalized' : 'In progress';
    return '$start • $status';
  }
}

class _KpiChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _KpiChip({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: valueColor)),
        ],
      ),
    );
  }
}

class _AnalyticsFiltersBar extends StatelessWidget {
  final AnalyticsFilters filters;
  final ValueChanged<AnalyticsFilters> onChanged;
  const _AnalyticsFiltersBar({required this.filters, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Wrap(
        runSpacing: 8,
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _DateChip(
            label: 'Start',
            date: filters.start,
            onTap: () async {
              final picked = await _pickDate(context, filters.start ?? DateTime.now());
              if (picked != null) onChanged(filters.copyWith(start: picked));
            },
          ),
          _DateChip(
            label: 'End',
            date: filters.end,
            onTap: () async {
              final picked = await _pickDate(context, filters.end ?? DateTime.now());
              if (picked != null) onChanged(filters.copyWith(end: picked));
            },
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Include in-progress'),
              Switch(
                value: filters.includeInProgress,
                onChanged: (v) => onChanged(filters.copyWith(includeInProgress: v)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<DateTime?> _pickDate(BuildContext context, DateTime initial) async {
    final now = DateTime.now();
    final first = DateTime(now.year - 5);
    final last = DateTime(now.year + 5);
    return showDatePicker(context: context, initialDate: initial, firstDate: first, lastDate: last);
  }
}

class _DateChip extends StatelessWidget {
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  const _DateChip({required this.label, required this.date, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = date == null ? 'Any' : DateFormat.yMMMd().format(date!);
    return ActionChip(label: Text('$label: $text'), onPressed: onTap);
  }
}

class _PlayerTile extends StatelessWidget {
  final PlayerAggregate p;
  final NumberFormat currency;
  const _PlayerTile({required this.p, required this.currency});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: CircleAvatar(child: Text(p.playerName.isNotEmpty ? p.playerName[0].toUpperCase() : '?')),
      title: Text(p.playerName, overflow: TextOverflow.ellipsis),
      subtitle: Text('${p.sessions} sessions'),
      trailing: Text(
        currency.format(p.netCents / 100),
        style: TextStyle(color: p.netCents == 0 ? Theme.of(context).colorScheme.outline : (p.netCents > 0 ? Colors.green : Colors.red)),
      ),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlayerDetailScreen(playerId: p.playerId, playerName: p.playerName),
          ),
        );
      },
    );
  }
}

void _showAllPlayersSheet(BuildContext context, AnalyticsState state) {
  final currency = NumberFormat.simpleCurrency();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      var sort = _PlayerSort.netGain;
      List<PlayerAggregate> compute(List<PlayerAggregate> list) {
        final copy = [...list];
        switch (sort) {
          case _PlayerSort.netGain:
            copy.sort((a, b) => b.netCents.compareTo(a.netCents));
            break;
          case _PlayerSort.netLoss:
            copy.sort((a, b) => a.netCents.compareTo(b.netCents));
            break;
          case _PlayerSort.sessions:
            copy.sort((a, b) => b.sessions.compareTo(a.sessions));
            break;
          case _PlayerSort.maxSingleWin:
            copy.sort((a, b) => b.maxSingleWinCents.compareTo(a.maxSingleWinCents));
            break;
          case _PlayerSort.maxSingleLoss:
            copy.sort((a, b) => a.maxSingleLossCents.compareTo(b.maxSingleLossCents));
            break;
        }
        return copy;
      }

      return StatefulBuilder(
        builder: (context, setState) {
          final items = compute(state.players);
          return SafeArea(
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.8,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              builder: (context, controller) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Row(
                        children: [
                          const Text('All players', style: TextStyle(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          DropdownButton<_PlayerSort>(
                            value: sort,
                            onChanged: (v) => setState(() => sort = v ?? _PlayerSort.netGain),
                            items: const [
                              DropdownMenuItem(value: _PlayerSort.netGain, child: Text('Net gain')),
                              DropdownMenuItem(value: _PlayerSort.netLoss, child: Text('Net loss')),
                              DropdownMenuItem(value: _PlayerSort.sessions, child: Text('Sessions')),
                              DropdownMenuItem(value: _PlayerSort.maxSingleWin, child: Text('Max single win')),
                              DropdownMenuItem(value: _PlayerSort.maxSingleLoss, child: Text('Max single loss')),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        controller: controller,
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => _AllPlayersRow(p: items[i], currency: currency, sort: sort),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      );
    },
  );
}

enum _PlayerSort { netGain, netLoss, sessions, maxSingleWin, maxSingleLoss }

class _AllPlayersRow extends StatelessWidget {
  final PlayerAggregate p;
  final NumberFormat currency;
  final _PlayerSort sort;
  const _AllPlayersRow({required this.p, required this.currency, required this.sort});

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(context).dividerColor;
    bool isHighlighted(_PlayerSort col) {
      if (col == _PlayerSort.netGain && (sort == _PlayerSort.netGain || sort == _PlayerSort.netLoss)) return true;
      return sort == col;
    }
    TextStyle labelStyle(_PlayerSort col) => Theme.of(context).textTheme.labelSmall!.copyWith(
          color: isHighlighted(col) ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline,
          fontWeight: isHighlighted(col) ? FontWeight.w700 : FontWeight.w400,
        );

    Color netValueColor() {
      if (p.netCents == 0) return Theme.of(context).colorScheme.outline;
      return p.netCents > 0 ? Colors.green : Colors.red;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PlayerDetailScreen(playerId: p.playerId, playerName: p.playerName),
                  ),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.playerName, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text('${p.sessions} sessions', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _metricCell(context, label: 'Max win', value: currency.format(p.maxSingleWinCents / 100), labelStyle: labelStyle(_PlayerSort.maxSingleWin)),
                  const SizedBox(width: 8),
                  Container(width: 1, height: 26, color: dividerColor),
                  const SizedBox(width: 8),
                  _metricCell(context, label: 'Max loss', value: currency.format(p.maxSingleLossCents / 100), labelStyle: labelStyle(_PlayerSort.maxSingleLoss)),
                  const SizedBox(width: 8),
                  Container(width: 1, height: 26, color: dividerColor),
                  const SizedBox(width: 8),
                  _metricCell(context, label: 'Net', value: currency.format(p.netCents / 100), labelStyle: labelStyle(_PlayerSort.netGain), valueColor: netValueColor()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricCell(BuildContext context, {required String label, required String value, TextStyle? labelStyle, Color? valueColor}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(label, style: labelStyle ?? Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
        Text(value, style: TextStyle(color: valueColor)),
      ],
    );
  }
}

Future<void> _exportAnalyticsCsv(AnalyticsState state) async {
  final rows = <List<dynamic>>[];
  final fmt = NumberFormat.simpleCurrency();
  rows.add(['KPI']);
  rows.add(['Total Sessions', state.totalSessions]);
  rows.add(['Total Players', state.totalPlayersSeen]);
  rows.add(['Global Net', fmt.format(state.globalNetCents / 100)]);
  rows.add([]);
  rows.add(['Players (sorted by net gain)']);
  rows.add(['Name', 'Sessions', 'Net', 'Max single win', 'Max single loss']);
  for (final p in state.players) {
    rows.add([
      p.playerName,
      p.sessions,
      fmt.format(p.netCents / 100),
      fmt.format(p.maxSingleWinCents / 100),
      fmt.format(p.maxSingleLossCents / 100),
    ]);
  }
  rows.add([]);
  rows.add(['Sessions']);
  rows.add(['Session ID', 'Players', 'Net']);
  for (final s in state.sessions) {
    rows.add([s.session.id ?? '', s.players, fmt.format(s.netCents / 100)]);
  }

  final csvStr = const ListToCsvConverter().convert(rows);
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, 'analytics_summary.csv'));
  await file.writeAsString(csvStr);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Analytics Summary CSV'));
}

// Player stats dialog removed; tapping players now navigates to PlayerDetailScreen.
