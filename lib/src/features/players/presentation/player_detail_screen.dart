import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/player_detail_repository.dart';
import '../../analytics/data/analytics_providers.dart';

class PlayerDetailScreen extends ConsumerStatefulWidget {
  final int playerId;
  final String playerName;
  const PlayerDetailScreen({super.key, required this.playerId, required this.playerName});

  @override
  ConsumerState<PlayerDetailScreen> createState() => _PlayerDetailScreenState();
}

class _PlayerSummary extends StatelessWidget {
  final int sessionsCount;
  final int sessionNetCents;
  final int quickAddNetCents;
  final int totalNetCents;
  final int totalBuyInCents;
  final int maxSingleWinCents;
  final int maxSingleLossCents; // negative or 0
  final DateTime? lastActive;

  const _PlayerSummary({
    required this.sessionsCount,
    required this.sessionNetCents,
    required this.quickAddNetCents,
    required this.totalNetCents,
    required this.totalBuyInCents,
    required this.maxSingleWinCents,
    required this.maxSingleLossCents,
    required this.lastActive,
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.simpleCurrency();
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
              stat('Games', sessionsCount.toString()),
              stat('Total buy-ins', currency.format(totalBuyInCents / 100)),
              stat('Game net', currency.format(sessionNetCents / 100), valueColor: netColor(sessionNetCents)),
              stat('Quick adds', currency.format(quickAddNetCents / 100), valueColor: netColor(quickAddNetCents)),
              stat('Total net', currency.format(totalNetCents / 100), valueColor: netColor(totalNetCents)),
              stat('Max single win', currency.format(maxSingleWinCents / 100)),
              stat('Max single loss', currency.format(maxSingleLossCents / 100)),
              stat('Last active', lastActive == null ? '—' : DateFormat.yMMMd().add_jm().format(lastActive!)),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayerDetailScreenState extends ConsumerState<PlayerDetailScreen> {
  final _repo = PlayerDetailRepository();
  late Future<_PlayerHistoryData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_PlayerHistoryData> _load() async {
    // Sessions should work for shared players via RLS
    List<Map<String, Object?>> sessions = [];
    try {
      sessions = await _repo.listPlayerSessionNets(widget.playerId);
    } catch (_) {
      // May fail for shared players - that's ok
    }
    
    // Quick adds are only visible for own players
    List<Map<String, Object?>> quickAdds = [];
    try {
      quickAdds = await _repo.listQuickAdds(widget.playerId);
    } catch (_) {
      // Expected for shared players - quick adds are private
    }
    
    // Total buy-ins from sessions
    int totalBuyIns = 0;
    try {
      totalBuyIns = await _repo.totalBuyInCents(widget.playerId);
    } catch (_) {
      // May fail for shared players
    }
    
    return _PlayerHistoryData(sessions: sessions, quickAdds: quickAdds, totalBuyInCents: totalBuyIns);
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _showQuickAddDialog() async {
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    bool isWin = true;
    final result = await showDialog<bool>(
      context: context,
      builder: (_) {
        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: const Text('Quick add'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment<bool>(value: true, label: Text('Win'), icon: Icon(Icons.add_circle_outline)),
                          ButtonSegment<bool>(value: false, label: Text('Loss'), icon: Icon(Icons.remove_circle_outline)),
                        ],
                        selected: {isWin},
                        onSelectionChanged: (s) => setState(() => isWin = s.first),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: noteController,
                  decoration: const InputDecoration(labelText: 'Note (optional)'),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
            ],
          );
        });
      },
    );
    if (result != true) return;

    // Parse amount (supports dollars.cents)
    final raw = amountController.text.trim();
    if (raw.isEmpty) return;
    final parsed = num.tryParse(raw.replaceAll(',', ''));
    if (parsed == null) return;
    final cents = (parsed * 100).round() * (isWin ? 1 : -1);
    await _repo.addQuickAdd(playerId: widget.playerId, amountCents: cents, note: noteController.text.trim().isEmpty ? null : noteController.text.trim());
    // Refresh analytics so global views reflect this change immediately
    await ref.read(analyticsProvider.notifier).refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Quick add saved')));
    }
    await _refresh();
    // Done
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.simpleCurrency();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playerName),
        actions: [
          IconButton(
            tooltip: 'Quick add',
            icon: const Icon(Icons.flash_on),
            onPressed: _showQuickAddDialog,
          ),
        ],
      ),
      body: FutureBuilder<_PlayerHistoryData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final data = snap.data!;
          // Compute summary stats
          final sessionsCount = data.sessions.length;
          final sessionNet = data.sessions.fold<int>(0, (p, s) => p + ((s['net_cents'] as int?) ?? 0));
          final quickAddNet = data.quickAdds.fold<int>(0, (p, q) => p + ((q['amount_cents'] as int?) ?? 0));
          final totalNet = sessionNet + quickAddNet;
          int maxWin = 0;
          int maxLoss = 0; // most negative
          for (final s in data.sessions) {
            final n = (s['net_cents'] as int?) ?? 0;
            if (n > maxWin) maxWin = n;
            if (n < maxLoss) maxLoss = n;
          }
          DateTime? lastActive;
          for (final s in data.sessions) {
            final startedAt = s['started_at'];
            if (startedAt == null) continue;
            final d = startedAt is String ? DateTime.parse(startedAt) : DateTime.fromMillisecondsSinceEpoch(startedAt as int);
            final la = lastActive;
            if (la == null || d.isAfter(la)) lastActive = d;
          }
          for (final q in data.quickAdds) {
            final createdAt = q['created_at'];
            if (createdAt == null) continue;
            final d = createdAt is String ? DateTime.parse(createdAt) : DateTime.fromMillisecondsSinceEpoch(createdAt as int);
            final la = lastActive;
            if (la == null || d.isAfter(la)) lastActive = d;
          }

          // Merge session nets and quick adds into a single list sorted by date desc
          final items = <_HistoryItem>[];
          for (final s in data.sessions) {
            final startedAt = s['started_at'];
            final when = startedAt is String ? DateTime.parse(startedAt) : (startedAt != null ? DateTime.fromMillisecondsSinceEpoch(startedAt as int) : DateTime.now());
            items.add(_HistoryItem.session(
              sessionId: s['session_id'] as int,
              sessionName: (s['session_name'] as String?) ?? 'Game #${s['session_id']}',
              when: when,
              netCents: (s['net_cents'] as int?) ?? 0,
            ));
          }
          for (final q in data.quickAdds) {
            final createdAt = q['created_at'];
            final when = createdAt is String ? DateTime.parse(createdAt) : (createdAt != null ? DateTime.fromMillisecondsSinceEpoch(createdAt as int) : DateTime.now());
            items.add(_HistoryItem.quickAdd(
              quickAddId: q['id'] as int?,
              when: when,
              amountCents: q['amount_cents'] as int,
              note: q['note'] as String?,
            ));
          }
          items.sort((a, b) => b.when.compareTo(a.when));

          if (items.isEmpty) {
            return const Center(child: Text('No history yet. Use Quick add to add an entry.'));
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              itemCount: items.length + 2,
              separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Card(
                    margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: _PlayerSummary(
                      sessionsCount: sessionsCount,
                      sessionNetCents: sessionNet,
                      quickAddNetCents: quickAddNet,
                      totalNetCents: totalNet,
                      totalBuyInCents: data.totalBuyInCents,
                      maxSingleWinCents: maxWin,
                      maxSingleLossCents: maxLoss,
                      lastActive: lastActive,
                    ),
                  );
                }
                if (index == 1) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text('History', style: Theme.of(context).textTheme.titleMedium),
                  );
                }
                final it = items[index - 2];
                final date = DateFormat.yMMMd().add_jm().format(it.when);
                if (it.type == _HistoryType.session) {
                  final amount = currency.format((it.netCents ?? 0) / 100);
                  final color = (it.netCents ?? 0) == 0
                      ? Theme.of(context).colorScheme.outline
                      : ((it.netCents ?? 0) > 0 ? Colors.green : Colors.red);
                  return ListTile(
                    leading: const Icon(Icons.casino),
                    title: Text(it.sessionName ?? 'Game'),
                    subtitle: Text(date),
                    trailing: Text(amount, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
                  );
                } else {
                  final amount = currency.format((it.amountCents ?? 0) / 100);
                  final color = (it.amountCents ?? 0) == 0
                      ? Theme.of(context).colorScheme.outline
                      : ((it.amountCents ?? 0) > 0 ? Colors.green : Colors.red);
                  return ListTile(
                    leading: const Icon(Icons.flash_on),
                    title: Text(it.note?.isNotEmpty == true ? it.note! : 'Quick add'),
                    subtitle: Text(date),
                    trailing: Text(amount, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
                    onLongPress: it.quickAddId == null
                        ? null
                        : () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('Delete quick add?'),
                                content: const Text('This action cannot be undone.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await _repo.deleteQuickAdd(it.quickAddId!);
                              await ref.read(analyticsProvider.notifier).refresh();
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Quick add deleted')));
                              }
                              await _refresh();
                            }
                          },
                  );
                }
              },
            ),
          );
        },
      ),
    );
  }
}

class _PlayerHistoryData {
  final List<Map<String, Object?>> sessions;
  final List<Map<String, Object?>> quickAdds;
  final int totalBuyInCents;
  _PlayerHistoryData({required this.sessions, required this.quickAdds, required this.totalBuyInCents});
}

enum _HistoryType { session, quickAdd }

class _HistoryItem {
  final _HistoryType type;
  final DateTime when;
  final int? netCents; // for session
  final String? sessionName; // for session
  final int? sessionId; // for session
  final int? amountCents; // for quick add
  final String? note; // for quick add
  final int? quickAddId; // for quick add

  _HistoryItem.session({required this.sessionId, required this.sessionName, required this.when, required int netCents})
      : type = _HistoryType.session,
        netCents = netCents,
        amountCents = null,
        note = null,
        quickAddId = null;

  _HistoryItem.quickAdd({this.quickAddId, required this.when, required int amountCents, this.note})
      : type = _HistoryType.quickAdd,
        amountCents = amountCents,
        netCents = null,
        sessionId = null,
        sessionName = null;
}
