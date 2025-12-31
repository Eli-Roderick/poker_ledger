import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../players/domain/player.dart';
import '../domain/session_models.dart';
import 'session_providers.dart' show sessionRepositoryProvider;

class SessionDetailState {
  final Session session;
  final List<SessionPlayer> participants;
  final List<Player> allPlayers;
  const SessionDetailState({required this.session, required this.participants, required this.allPlayers});
}

final sessionDetailProvider = FutureProvider.family<SessionDetailState, int>((ref, sessionId) async {
  final repo = ref.read(sessionRepositoryProvider);
  final session = await repo.getSessionById(sessionId) ?? (throw StateError('Session not found: $sessionId'));
  final rows = await repo.listSessionPlayersWithNames(sessionId);
  final participants = rows
      .map((m) => SessionPlayer(
            id: m['sp_id'] as int,
            sessionId: m['session_id'] as int,
            playerId: m['player_id'] as int,
            buyInCentsTotal: m['buy_in_cents_total'] as int,
            cashOutCents: m['cash_out_cents'] as int?,
            paidUpfront: (m['paid_upfront'] as int) == 1,
            settlementDone: ((m['settlement_done'] as int?) ?? 0) == 1,
          ))
      .toList();
  final allPlayers = await repo.getAllPlayers();
  return SessionDetailState(session: session, participants: participants, allPlayers: allPlayers);
});
