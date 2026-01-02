import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../players/domain/player.dart';
import '../data/session_providers.dart';
import '../domain/session_models.dart';

class SessionScreen extends ConsumerWidget {
  static const routeName = '/session';
  const SessionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(openSessionProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Poker Session'),
        actions: [
          IconButton(
            tooltip: 'Finalize session',
            icon: const Icon(Icons.check_circle_outline),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Finalize session?'),
                  content: const Text('You will compute settlements later. This locks the session timing.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Finalize')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(openSessionProvider.notifier).finalize();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Game finalized')));
                }
              }
            },
          )
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (data) {
          final participants = data.participants;
          final allPlayers = data.allPlayers;
          return RefreshIndicator(
            onRefresh: () => ref.read(openSessionProvider.notifier).refresh(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionHeader(title: 'Participants (${participants.length})'),
                if (participants.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32.0),
                    child: Center(child: Text('No participants yet. Add players below.')),
                  )
                else
                  ...participants.map((sp) {
                    final player = allPlayers.firstWhere((p) => p.id == sp.playerId);
                    return _ParticipantCard(sp: sp, player: player);
                  }),
                const SizedBox(height: 24),
                _SectionHeader(title: 'Add Player'),
                _AddParticipantTile(allPlayers: allPlayers, participants: participants),
              ],
            ),
          );
        },
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
  final SessionPlayer sp;
  final Player player;
  const _ParticipantCard({required this.sp, required this.player});

  String _fmtCents(int cents) => NumberFormat.simpleCurrency().format(cents / 100);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: ListTile(
        title: Text(player.name),
        subtitle: Text('Buy-ins total: ${_fmtCents(sp.buyInCentsTotal)} • ${sp.paidUpfront ? 'Paid' : 'Unpaid'}'),
        trailing: IconButton(
          tooltip: 'Add rebuy',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () async {
            final cents = await showDialog<int?>(
              context: context,
              builder: (_) => const _MoneyInputDialog(title: 'Add Rebuy'),
            );
            if (cents != null && cents > 0) {
              await ref.read(openSessionProvider.notifier).addRebuy(sessionPlayerId: sp.id!, amountCents: cents);
            }
          },
        ),
      ),
    );
  }
}

class _AddParticipantTile extends ConsumerWidget {
  final List<Player> allPlayers;
  final List<SessionPlayer> participants;
  const _AddParticipantTile({required this.allPlayers, required this.participants});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final existingIds = participants.map((e) => e.playerId).toSet();
    final available = allPlayers.where((p) => p.id != null && !existingIds.contains(p.id)).toList();
    return ListTile(
      leading: const Icon(Icons.person_add),
      title: const Text('Add player to session'),
      subtitle: Text(available.isEmpty ? 'All players already added' : 'Choose player and initial buy-in'),
      onTap: available.isEmpty
          ? null
          : () async {
              final result = await showDialog<_AddParticipantResult?>(
                context: context,
                builder: (_) => _AddParticipantDialog(players: available),
              );
              if (result != null) {
                await ref.read(openSessionProvider.notifier).addPlayer(
                      playerId: result.playerId,
                      initialBuyInCents: result.initialBuyInCents,
                      paidUpfront: result.paidUpfront,
                    );
              }
            },
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
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Paid upfront'),
                value: _paidUpfront,
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
