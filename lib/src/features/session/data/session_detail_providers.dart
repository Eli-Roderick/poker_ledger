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
            buyInCentsTotal: m['buy_in_cents_total'] as int? ?? 0,
            cashOutCents: m['cash_out_cents'] as int?,
            paidUpfront: m['paid_upfront'] as bool? ?? true,
            settlementDone: m['settlement_done'] as bool? ?? false,
          ))
      .toList();
  // Build player list from session data (works for shared sessions too)
  // Also try to get user's own players for adding new participants
  final playersFromSession = rows.map((m) => Player(
    id: m['player_id'] as int,
    name: m['player_name'] as String? ?? 'Unknown',
    email: m['player_email'] as String?,
    active: m['player_active'] as bool? ?? true,
    createdAt: DateTime.now(), // Placeholder - not used for display
  )).toList();
  
  // Try to get user's own players, but don't fail if empty
  List<Player> ownPlayers = [];
  try {
    ownPlayers = await repo.getAllPlayers();
  } catch (_) {
    // Ignore - user may be viewing a shared session
  }
  
  // Combine: session players + own players (deduplicated by id)
  final playerIds = <int>{};
  final allPlayers = <Player>[];
  for (final p in [...playersFromSession, ...ownPlayers]) {
    if (p.id != null && !playerIds.contains(p.id)) {
      playerIds.add(p.id!);
      allPlayers.add(p);
    }
  }
  
  return SessionDetailState(session: session, participants: participants, allPlayers: allPlayers);
});
