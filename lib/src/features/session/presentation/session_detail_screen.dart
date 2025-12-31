import 'package:flutter/material.dart';
import '../../analytics/data/analytics_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../players/domain/player.dart';
import '../data/session_detail_providers.dart';
import '../data/session_providers.dart';
import '../data/sessions_list_providers.dart';
import 'session_summary_screen.dart';
// banker screens removed from navigation; summary combines flows

class SessionDetailScreen extends ConsumerWidget {
  final int sessionId;
  const SessionDetailScreen({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(sessionDetailProvider(sessionId));
    final sessionName = asyncState.valueOrNull?.session.name;
    return Scaffold(
      appBar: AppBar(
        title: Text((sessionName == null || sessionName.trim().isEmpty) ? 'Session #$sessionId' : sessionName),
        actions: [
          IconButton(
            tooltip: 'Finalize session',
            icon: const Icon(Icons.check_circle_outline),
            onPressed: () async {
              // Validation: require all cash outs entered
              try {
                final detail = await ref.read(sessionDetailProvider(sessionId).future);
                final missing = detail.participants.where((p) => p.cashOutCents == null).length;
                if (missing > 0) {
                  if (context.mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Cash outs required'),
                        content: Text(
                          'Please enter cash outs for all players before finalizing. Missing: $missing',
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
                        ],
                      ),
                    );
                  }
                  return;
                }
                // Additional validation for banker mode: ensure all debtors have paid upfront (not needed if even)
                final isBanker = detail.session.settlementMode == 'banker' && detail.session.bankerSessionPlayerId != null;
                if (isBanker) {
                  final bankerSpId = detail.session.bankerSessionPlayerId!;
                  final notSettled = <String>[];
                  for (final p in detail.participants) {
                    if (p.id == bankerSpId) continue;
                    final net = (p.cashOutCents ?? 0) - p.buyInCentsTotal;
                    if (net != 0 && p.settlementDone != true) {
                      final name = detail.allPlayers.firstWhere((e) => e.id == p.playerId).name;
                      notSettled.add(name);
                    }
                  }
                  if (notSettled.isNotEmpty) {
                    if (context.mounted) {
                      await showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Unsettled transactions'),
                          content: Text(
                            'Mark these settlements as paid before finalizing:\n\n- ${notSettled.join('\n- ')}',
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
                          ],
                        ),
                      );
                    }
                    return;
                  }
                }
              } catch (_) {}
              if (!context.mounted) return;
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Finalize session?'),
                  content: const Text('This locks the session timing and marks it complete.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Finalize')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(sessionRepositoryProvider).finalizeSession(sessionId);
                ref.invalidate(sessionDetailProvider(sessionId));
                // Recompute analytics immediately so the new data shows up
                await ref.read(analyticsProvider.notifier).refresh();
                ref.read(sessionsListProvider.notifier).refresh();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Session finalized')));
                }
              }
            },
          ),
          IconButton(
            tooltip: 'Delete session',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Delete session?'),
                  content: const Text('This will remove the session and all of its data.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(sessionRepositoryProvider).deleteSession(sessionId);
                // Update analytics promptly after deletion
                await ref.read(analyticsProvider.notifier).refresh();
                if (context.mounted) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Session deleted')));
                }
                // refresh sessions list
                ref.read(sessionsListProvider.notifier).refresh();
              }
            },
          ),
        ],
      ),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (data) {
          final participants = data.participants;
          final allPlayers = data.allPlayers;
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(sessionDetailProvider(sessionId)),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(child: _SectionHeader(title: 'Participants (${participants.length})')),
                    TextButton.icon(
                      icon: const Icon(Icons.person_add),
                      label: const Text('Add player'),
                      onPressed: () async {
                        // Inline Add Player flow (moved from separate section)
                        final existingIds = participants.map((e) => e.playerId).toSet();
                        final latestPlayers = await ref.read(sessionRepositoryProvider).getAllPlayers(activeOnly: true);
                        final freshAvailable = latestPlayers.where((p) => p.id != null && !existingIds.contains(p.id)).toList();
                        if (freshAvailable.isEmpty) return;
                        if (!context.mounted) return;
                        final result = await showDialog<_AddParticipantResult?> (
                          context: context,
                          builder: (_) => _AddParticipantDialog(players: freshAvailable),
                        );
                        if (result != null) {
                          await ref.read(sessionRepositoryProvider).addPlayerToSession(
                                sessionId: sessionId,
                                playerId: result.playerId,
                                initialBuyInCents: result.initialBuyInCents,
                                paidUpfront: result.paidUpfront,
                              );
                          ref.invalidate(sessionDetailProvider(sessionId));
                        }
                      },
                    ),
                  ],
                ),
                if (participants.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32.0),
                    child: Center(child: Text('No participants yet. Add players below.')),
                  )
                else
                  ...participants.map((sp) {
                    final player = allPlayers.firstWhere((p) => p.id == sp.playerId);
                    final hidePaid = data.session.settlementMode == 'banker' && data.session.bankerSessionPlayerId == sp.id;
                    return _ParticipantCard(sp: sp, player: player, sessionId: sessionId, showPaidStatus: !hidePaid);
                  }),
                const SizedBox(height: 24),
                _SectionHeader(title: 'Settlement Mode'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Column(
                      children: [
                        RadioListTile<String>(
                          title: const Text('Pairwise (default)'),
                          subtitle: const Text('Everyone settles with each other via minimal transfers'),
                          value: 'pairwise',
                          groupValue: data.session.settlementMode,
                          onChanged: (v) async {
                            if (v == null || v == data.session.settlementMode) return;
                            await ref.read(sessionRepositoryProvider).setSettlementMode(sessionId: sessionId, mode: v);
                            await ref.read(sessionRepositoryProvider).setBanker(sessionId: sessionId, bankerSessionPlayerId: null);
                            ref.invalidate(sessionDetailProvider(sessionId));
                          },
                        ),
                        RadioListTile<String>(
                          title: const Text('Banker'),
                          subtitle: const Text('Everyone pays one banker upfront; banker pays winners at the end'),
                          value: 'banker',
                          groupValue: data.session.settlementMode,
                          onChanged: (v) async {
                            if (v == null || v == data.session.settlementMode) return;
                            await ref.read(sessionRepositoryProvider).setSettlementMode(sessionId: sessionId, mode: v);
                            ref.invalidate(sessionDetailProvider(sessionId));
                          },
                        ),
                        if (data.session.settlementMode == 'banker') ...[
                          const Divider(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                            child: Row(
                              children: [
                                const Text('Banker:'),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    value: data.session.bankerSessionPlayerId,
                                    items: participants
                                        .map((sp) {
                                          final p = allPlayers.firstWhere((pl) => pl.id == sp.playerId);
                                          return DropdownMenuItem<int>(value: sp.id, child: Text(p.name));
                                        })
                                        .toList(),
                                    onChanged: (val) async {
                                      await ref
                                          .read(sessionRepositoryProvider)
                                          .setBanker(sessionId: sessionId, bankerSessionPlayerId: val);
                                      ref.invalidate(sessionDetailProvider(sessionId));
                                    },
                                    decoration: const InputDecoration(hintText: 'Select banker'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Buttons removed: access the combined Summary from app bar menu
                        ] else ...[
                          // Buttons removed: access the combined Summary from app bar menu
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: FilledButton.icon(
            icon: const Icon(Icons.summarize_outlined),
            label: const Text('Session Summary'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => SessionSummaryScreen(sessionId: sessionId)),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}

class _ParticipantCard extends ConsumerWidget {
  final dynamic sp; // SessionPlayer
  final Player player;
  final int sessionId;
  final bool showPaidStatus;
  const _ParticipantCard({required this.sp, required this.player, required this.sessionId, this.showPaidStatus = true});

  String _fmtCents(int cents) => NumberFormat.simpleCurrency().format(cents / 100);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: ListTile(
        title: Text(player.name),
        subtitle: Text(
          showPaidStatus
              ? 'Buy-ins total: ${_fmtCents(sp.buyInCentsTotal)} • ${sp.paidUpfront ? 'Paid' : 'Unpaid'}'
              : 'Buy-ins total: ${_fmtCents(sp.buyInCentsTotal)}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Add rebuy',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () async {
                final cents = await showDialog<int?> (
                  context: context,
                  builder: (_) => const _MoneyInputDialog(title: 'Add Rebuy'),
                );
                if (cents != null && cents > 0) {
                  await ref.read(sessionRepositoryProvider).addRebuy(sessionPlayerId: sp.id!, amountCents: cents);
                  ref.invalidate(sessionDetailProvider(sessionId));
                }
              },
            ),
            IconButton(
              tooltip: 'Remove from session',
              icon: const Icon(Icons.person_remove_alt_1_outlined),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Remove participant?'),
                    content: Text('Remove ${player.name} and their rebuys from this session?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
                    ],
                  ),
                );
                if (ok == true) {
                  await ref.read(sessionRepositoryProvider).deleteSessionPlayer(sp.id!);
                  ref.invalidate(sessionDetailProvider(sessionId));
                  // Update analytics promptly
                  await ref.read(analyticsProvider.notifier).refresh();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${player.name} removed')));
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _AddParticipantResult {
  final int playerId;
  final int initialBuyInCents;
  final bool paidUpfront;
  const _AddParticipantResult({required this.playerId, required this.initialBuyInCents, required this.paidUpfront});
}

class _AddParticipantDialog extends StatefulWidget {
  final List<Player> players;
  const _AddParticipantDialog({required this.players});

  @override
  State<_AddParticipantDialog> createState() => _AddParticipantDialogState();
}

class _AddParticipantDialogState extends State<_AddParticipantDialog> {
  int? _playerId;
  final _buyInCtrl = TextEditingController(text: '20.00');
  bool _paidUpfront = true;

  @override
  void dispose() {
    _buyInCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Participant'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            // Cap dialog content height so it stays scrollable on small screens/with keyboard
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                value: _playerId,
                isExpanded: true,
                items: widget.players
                    .map((p) => DropdownMenuItem<int>(value: p.id, child: Text(p.name)))
                    .toList(),
                onChanged: (v) => setState(() => _playerId = v),
                decoration: const InputDecoration(labelText: 'Player'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _buyInCtrl,
                decoration: const InputDecoration(labelText: 'Initial buy-in (e.g., 20.00)'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  OutlinedButton(
                    onPressed: () => setState(() => _buyInCtrl.text = '5.00'),
                    child: const Text('\$5'),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(() => _buyInCtrl.text = '10.00'),
                    child: const Text('\$10'),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(() => _buyInCtrl.text = '20.00'),
                    child: const Text('\$20'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Paid upfront'),
                value: _paidUpfront,
                visualDensity: const VisualDensity(vertical: -3),
                onChanged: (v) => setState(() => _paidUpfront = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_playerId == null) return;
            final cents = _parseMoneyToCents(_buyInCtrl.text);
            Navigator.pop(
              context,
              _AddParticipantResult(playerId: _playerId!, initialBuyInCents: cents, paidUpfront: _paidUpfront),
            );
          },
          child: const Text('Add'),
        )
      ],
    );
  }

  int _parseMoneyToCents(String input) {
    final cleaned = input.replaceAll(RegExp('[^0-9.,]'), '').replaceAll(',', '.');
    final value = double.tryParse(cleaned) ?? 0.0;
    return (value * 100).round();
  }
}

class _MoneyInputDialog extends StatefulWidget {
  final String title;
  const _MoneyInputDialog({required this.title});
  @override
  State<_MoneyInputDialog> createState() => _MoneyInputDialogState();
}

class _MoneyInputDialogState extends State<_MoneyInputDialog> {
  final _ctrl = TextEditingController(text: '20.00');
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        decoration: const InputDecoration(labelText: 'Amount (e.g., 20.00)'),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final cleaned = _ctrl.text.replaceAll(RegExp('[^0-9.,]'), '').replaceAll(',', '.');
            final value = double.tryParse(cleaned) ?? 0.0;
            Navigator.pop(context, (value * 100).round());
          },
          child: const Text('Add'),
        )
      ],
    );
  }
}
