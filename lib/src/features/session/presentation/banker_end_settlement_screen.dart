import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/session_detail_providers.dart';

class BankerEndSettlementScreen extends ConsumerWidget {
  final int sessionId;
  const BankerEndSettlementScreen({super.key, required this.sessionId});

  String _fmt(int cents) => NumberFormat.simpleCurrency().format(cents / 100);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(sessionDetailProvider(sessionId));
    return Scaffold(
      appBar: AppBar(title: const Text('Banker: End Settlement')),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (data) {
          final session = data.session;
          final bankerSpId = session.bankerSessionPlayerId;
          if (session.settlementMode != 'banker' || bankerSpId == null) {
            return const Center(child: Text('Switch to banker mode and select a banker.'));
          }
          final bankerSp = data.participants.firstWhere((p) => p.id == bankerSpId);
          final bankerName = data.allPlayers.firstWhere((p) => p.id == bankerSp.playerId).name;

          final lines = <_Line>[];
          int bankerNet = 0;
          for (final sp in data.participants) {
            final net = (sp.cashOutCents ?? 0) - sp.buyInCentsTotal; // + won, - lost
            if (sp.id == bankerSpId) {
              bankerNet += net;
            } else {
              // For non-banker: if net < 0 they owe banker; if net > 0 banker owes them
              lines.add(_Line(playerId: sp.playerId, netCents: net));
              bankerNet -= net; // keep banker opposite of others to maintain zero-sum check
            }
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Banker: $bankerName', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (lines.isEmpty)
                const Text('No participants.')
              else
                ...lines.map((l) {
                  final name = data.allPlayers.firstWhere((p) => p.id == l.playerId).name;
                  if (l.netCents < 0) {
                    // player lost -> owes banker
                    return ListTile(
                      leading: const Icon(Icons.arrow_upward, color: Colors.redAccent),
                      title: Text('$name pays banker'),
                      trailing: Text(_fmt(-l.netCents)),
                    );
                  } else if (l.netCents > 0) {
                    // player won -> banker owes player
                    return ListTile(
                      leading: const Icon(Icons.arrow_downward, color: Colors.green),
                      title: Text('Banker pays $name'),
                      trailing: Text(_fmt(l.netCents)),
                    );
                  } else {
                    return ListTile(
                      leading: const Icon(Icons.horizontal_rule),
                      title: Text('$name is even'),
                    );
                  }
                }),
              const Divider(height: 24),
              ListTile(
                leading: const Icon(Icons.summarize),
                title: const Text('Banker net'),
                subtitle: const Text('Positive means banker pays out overall; negative means banker collects'),
                trailing: Text(_fmt(bankerNet)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Line {
  final int playerId;
  final int netCents;
  _Line({required this.playerId, required this.netCents});
}
