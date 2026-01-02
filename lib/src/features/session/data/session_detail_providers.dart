import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../players/domain/player.dart';
import '../domain/session_models.dart';
import 'session_providers.dart' show sessionRepositoryProvider;

class SessionDetailState {
  final Session session;
  final List<SessionPlayer> participants;
  final List<Player> allPlayers;
  const SessionDetailState({required this.session, required this.participants, required this.allPlayers});
  
  SessionDetailState copyWith({
    Session? session,
    List<SessionPlayer>? participants,
    List<Player>? allPlayers,
  }) {
    return SessionDetailState(
      session: session ?? this.session,
      participants: participants ?? this.participants,
      allPlayers: allPlayers ?? this.allPlayers,
    );
  }
}

/// Notifier for session detail with optimistic updates
class SessionDetailNotifier extends FamilyAsyncNotifier<SessionDetailState, int> {
  @override
  Future<SessionDetailState> build(int sessionId) async {
    return _fetchData(sessionId);
  }
  
  Future<SessionDetailState> _fetchData(int sessionId) async {
    final repo = ref.read(sessionRepositoryProvider);
    
    // Run queries in parallel for better performance
    final results = await Future.wait([
      repo.getSessionById(sessionId),
      repo.listSessionPlayersWithNames(sessionId),
      repo.getAllPlayers().catchError((_) => <Player>[]),
    ]);
    
    final session = results[0] as Session?;
    if (session == null) throw StateError('Session not found: $sessionId');
    
    final rows = results[1] as List<Map<String, Object?>>;
    final ownPlayers = results[2] as List<Player>;
    
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
    
    final playersFromSession = rows.map((m) => Player(
      id: m['player_id'] as int,
      name: m['player_name'] as String? ?? 'Unknown',
      email: m['player_email'] as String?,
      active: m['player_active'] as bool? ?? true,
      createdAt: DateTime.now(),
    )).toList();
    
    final playerIds = <int>{};
    final allPlayers = <Player>[];
    for (final p in [...playersFromSession, ...ownPlayers]) {
      if (p.id != null && !playerIds.contains(p.id)) {
        playerIds.add(p.id!);
        allPlayers.add(p);
      }
    }
    
    return SessionDetailState(session: session, participants: participants, allPlayers: allPlayers);
  }
  
  /// Add player with optimistic update
  Future<void> addPlayer({required int playerId, required int initialBuyInCents}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    
    // Player lookup for optimistic update
    final _ = current.allPlayers.firstWhere((p) => p.id == playerId);
    
    // Optimistic update - add player immediately with temporary ID
    final tempSp = SessionPlayer(
      id: -1, // Temporary ID
      sessionId: arg,
      playerId: playerId,
      buyInCentsTotal: initialBuyInCents,
      cashOutCents: null,
      paidUpfront: false,
      settlementDone: false,
    );
    state = AsyncData(current.copyWith(
      participants: [...current.participants, tempSp],
    ));
    
    // Perform actual database operation
    try {
      await ref.read(sessionRepositoryProvider).addPlayerToSession(
        sessionId: arg,
        playerId: playerId,
        initialBuyInCents: initialBuyInCents,
        paidUpfront: false,
      );
      // Refresh to get real ID
      state = AsyncData(await _fetchData(arg));
    } catch (e) {
      // Revert on error
      state = AsyncData(current);
      rethrow;
    }
  }
  
  /// Add rebuy with optimistic update
  Future<void> addRebuy({required int sessionPlayerId, required int amountCents}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    
    // Optimistic update
    final updatedParticipants = current.participants.map((sp) {
      if (sp.id == sessionPlayerId) {
        return SessionPlayer(
          id: sp.id,
          sessionId: sp.sessionId,
          playerId: sp.playerId,
          buyInCentsTotal: sp.buyInCentsTotal + amountCents,
          cashOutCents: sp.cashOutCents,
          paidUpfront: sp.paidUpfront,
          settlementDone: sp.settlementDone,
        );
      }
      return sp;
    }).toList();
    state = AsyncData(current.copyWith(participants: updatedParticipants));
    
    // Perform actual database operation
    try {
      await ref.read(sessionRepositoryProvider).addRebuy(
        sessionPlayerId: sessionPlayerId,
        amountCents: amountCents,
      );
    } catch (e) {
      // Revert on error
      state = AsyncData(current);
      rethrow;
    }
  }
  
  /// Delete player with optimistic update
  Future<void> deletePlayer({required int sessionPlayerId}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    
    // Optimistic update
    final updatedParticipants = current.participants.where((sp) => sp.id != sessionPlayerId).toList();
    state = AsyncData(current.copyWith(participants: updatedParticipants));
    
    // Perform actual database operation
    try {
      await ref.read(sessionRepositoryProvider).deleteSessionPlayer(sessionPlayerId);
    } catch (e) {
      // Revert on error
      state = AsyncData(current);
      rethrow;
    }
  }
  
  /// Update cash out with optimistic update
  Future<void> updateCashOut({required int sessionPlayerId, required int? cashOutCents}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    
    // Optimistic update
    final updatedParticipants = current.participants.map((sp) {
      if (sp.id == sessionPlayerId) {
        return SessionPlayer(
          id: sp.id,
          sessionId: sp.sessionId,
          playerId: sp.playerId,
          buyInCentsTotal: sp.buyInCentsTotal,
          cashOutCents: cashOutCents,
          paidUpfront: sp.paidUpfront,
          settlementDone: sp.settlementDone,
        );
      }
      return sp;
    }).toList();
    state = AsyncData(current.copyWith(participants: updatedParticipants));
    
    // Perform actual database operation (don't await - fire and forget for speed)
    ref.read(sessionRepositoryProvider).updateCashOut(
      sessionPlayerId: sessionPlayerId,
      cashOutCents: cashOutCents,
    );
  }
  
  /// Set settlement mode with optimistic update
  Future<void> setSettlementMode({required String mode}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    
    // Optimistic update
    final updatedSession = Session(
      id: current.session.id,
      name: current.session.name,
      startedAt: current.session.startedAt,
      endedAt: current.session.endedAt,
      finalized: current.session.finalized,
      settlementMode: mode,
      bankerSessionPlayerId: mode == 'pairwise' ? null : current.session.bankerSessionPlayerId,
    );
    state = AsyncData(current.copyWith(session: updatedSession));
    
    // Perform actual database operation
    await ref.read(sessionRepositoryProvider).setSettlementMode(sessionId: arg, mode: mode);
    if (mode == 'pairwise') {
      await ref.read(sessionRepositoryProvider).setBanker(sessionId: arg, bankerSessionPlayerId: null);
    }
  }
  
  /// Set banker with optimistic update
  Future<void> setBanker({required int? bankerSessionPlayerId}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    
    // Optimistic update
    final updatedSession = Session(
      id: current.session.id,
      name: current.session.name,
      startedAt: current.session.startedAt,
      endedAt: current.session.endedAt,
      finalized: current.session.finalized,
      settlementMode: current.session.settlementMode,
      bankerSessionPlayerId: bankerSessionPlayerId,
    );
    state = AsyncData(current.copyWith(session: updatedSession));
    
    // Perform actual database operation
    await ref.read(sessionRepositoryProvider).setBanker(sessionId: arg, bankerSessionPlayerId: bankerSessionPlayerId);
  }
  
  /// Refresh data from database
  Future<void> refresh() async {
    state = AsyncData(await _fetchData(arg));
  }
}

final sessionDetailProvider = AsyncNotifierProvider.family<SessionDetailNotifier, SessionDetailState, int>(
  SessionDetailNotifier.new,
);
