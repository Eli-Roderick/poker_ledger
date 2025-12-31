import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/session_detail_providers.dart';
import '../data/session_providers.dart';

class BankerStartSummaryScreen extends ConsumerWidget {
  final int sessionId;
  const BankerStartSummaryScreen({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(sessionDetailProvider(sessionId));
    return Scaffold(
      appBar: AppBar(title: const Text('Banker: Start Summary')),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (data) {
          final participants = data.participants;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Mark who paid the banker upfront:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              ...participants.map((sp) {
                final player = data.allPlayers.firstWhere((p) => p.id == sp.playerId);
                return SwitchListTile(
                  title: Text(player.name),
                  subtitle: const Text('Paid upfront'),
                  value: sp.paidUpfront,
                  onChanged: (v) async {
                    await ref.read(sessionRepositoryProvider).updatePaidUpfront(sessionPlayerId: sp.id!, paidUpfront: v);
                    ref.invalidate(sessionDetailProvider(sessionId));
                  },
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
