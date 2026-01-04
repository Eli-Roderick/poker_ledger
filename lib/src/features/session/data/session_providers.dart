import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/auth_providers.dart';
import '../../players/domain/player.dart';
import '../domain/session_models.dart';
import 'session_repository.dart';

final sessionRepositoryProvider = Provider<SessionRepository>((ref) => SessionRepository());

class OpenSessionState {
  final Session session;
  final List<SessionPlayer> participants; // raw
  final List<Player> allPlayers;
  const OpenSessionState({required this.session, required this.participants, required this.allPlayers});
}

class OpenSessionNotifier extends AsyncNotifier<OpenSessionState> {
  SessionRepository get _repo => ref.read(sessionRepositoryProvider);

  @override
  Future<OpenSessionState> build() async {
    // Watch auth state to auto-refresh when user changes
    final user = ref.watch(currentUserProvider);
    if (user == null) {
      throw Exception('Not authenticated');
    }
    
    final session = await _repo.getOrCreateOpenSession();
    final participants = await _listSessionPlayers(session.id!);
    final allPlayers = await _repo.getAllPlayers();
    return OpenSessionState(session: session, participants: participants, allPlayers: allPlayers);
  }

  Future<List<SessionPlayer>> _listSessionPlayers(int sessionId) async {
    final dbPlayers = await _repo.listSessionPlayersWithNames(sessionId);
    // Map back to SessionPlayer model for simplicity here
    return dbPlayers
        .map((m) => SessionPlayer(
              id: m['sp_id'] as int,
              sessionId: m['session_id'] as int,
              playerId: m['player_id'] as int,
              buyInCentsTotal: m['buy_in_cents_total'] as int? ?? 0,
              paidUpfront: m['paid_upfront'] as bool? ?? true,
            ))
        .toList();
  }

  Future<void> refresh() async {
    final s = await _repo.getOrCreateOpenSession();
    final participants = await _listSessionPlayers(s.id!);
    final allPlayers = await _repo.getAllPlayers();
    state = AsyncData(OpenSessionState(session: s, participants: participants, allPlayers: allPlayers));
  }

  Future<void> addPlayer({
    required int playerId,
    required int initialBuyInCents,
    required bool paidUpfront,
  }) async {
    final s = (state.value ?? await build()).session;
    await _repo.addPlayerToSession(
      sessionId: s.id!,
      playerId: playerId,
      initialBuyInCents: initialBuyInCents,
      paidUpfront: paidUpfront,
    );
    await refresh();
  }

  Future<void> addRebuy({required int sessionPlayerId, required int amountCents}) async {
    await _repo.addRebuy(sessionPlayerId: sessionPlayerId, amountCents: amountCents);
    await refresh();
  }

  Future<void> finalize() async {
    final s = (state.value ?? await build()).session;
    await _repo.finalizeSession(s.id!);
    await refresh();
  }
}

final openSessionProvider = AsyncNotifierProvider<OpenSessionNotifier, OpenSessionState>(() => OpenSessionNotifier());
