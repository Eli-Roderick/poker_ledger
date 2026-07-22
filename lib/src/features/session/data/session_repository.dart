import 'package:supabase_flutter/supabase_flutter.dart' hide Session;
import '../../../config/backend_contract.dart';
import '../../players/domain/player.dart';
import '../domain/session_models.dart';
import '../../../utils/idempotency_key.dart';

/// Legacy compatibility reads/writes and cross-version read models.
///
/// New version 2 games are changed only through the V2 repository. The mutable
/// methods here are retained only for unresolved version 1 games and are
/// rejected by database guards for version 2 rows.
class SessionRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<void> updateSettlementDone({
    required int sessionPlayerId,
    required bool done,
  }) async {
    await _client
        .from('session_players')
        .update({'settlement_done': done})
        .eq('id', sessionPlayerId);
  }

  Future<void> updatePaidUpfront({
    required int sessionPlayerId,
    required bool paidUpfront,
  }) async {
    await _client
        .from('session_players')
        .update({'paid_upfront': paidUpfront})
        .eq('id', sessionPlayerId);
  }

  Future<void> setSettlementMode({
    required int sessionId,
    required String mode,
  }) async {
    await _client
        .from('sessions')
        .update({'settlement_mode': mode})
        .eq('id', sessionId);
  }

  Future<void> setBanker({
    required int sessionId,
    required int? bankerSessionPlayerId,
  }) async {
    await _client
        .from('sessions')
        .update({'banker_session_player_id': bankerSessionPlayerId})
        .eq('id', sessionId);
  }

  Future<void> updateCashOut({
    required int sessionPlayerId,
    required int? cashOutCents,
  }) async {
    await _client.rpc(
      'set_legacy_cash_out',
      params: {
        'p_session_player_id': sessionPlayerId,
        'p_cash_out_cents': cashOutCents,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> deleteSession(int sessionId) async {
    // Only delete sessions owned by the current user
    await _client
        .from('sessions')
        .delete()
        .eq('id', sessionId)
        .eq('user_id', _client.auth.currentUser!.id);
  }

  Future<void> deleteSessionPlayer(int sessionPlayerId) async {
    // Clear banker reference first
    await _client
        .from('sessions')
        .update({'banker_session_player_id': null})
        .eq('banker_session_player_id', sessionPlayerId);
    // Delete the session player (rebuys will cascade)
    await _client.from('session_players').delete().eq('id', sessionPlayerId);
  }

  Future<void> renameSession({
    required int sessionId,
    required String? name,
  }) async {
    // Only update sessions owned by the current user
    await _client
        .from('sessions')
        .update({'name': name})
        .eq('id', sessionId)
        .eq('user_id', _client.auth.currentUser!.id);
  }

  Future<void> finalizeSession(int sessionId) async {
    await _client.rpc(
      'finalize_legacy_session',
      params: {'p_session_id': sessionId},
    );
  }

  Future<List<Session>> listSessions() async {
    // Only return sessions owned by the current user
    final data = await _client
        .from('sessions')
        .select()
        .eq('user_id', _client.auth.currentUser!.id)
        .order('started_at', ascending: false);
    return (data as List).map((e) => Session.fromMap(e)).toList();
  }

  /// List sessions the current user owns
  Future<List<Session>> listMySessions() async {
    final data = await _client
        .from('sessions')
        .select()
        .eq('user_id', _client.auth.currentUser!.id)
        .order('started_at', ascending: false);
    return (data as List).map((e) => Session.fromMap(e)).toList();
  }

  /// Games relevant to personal stats: hosted games and games where the
  /// current account was an accepted participant. Group membership alone does
  /// not change a person's own totals.
  Future<List<SessionWithOwner>> listPersonalSessions() async {
    final userId = _client.auth.currentUser!.id;
    final visible = await listAllVisibleSessions();
    if (visible.isEmpty) return [];
    final rows = await _client
        .from('session_players')
        .select('session_id, profile_id, players(linked_user_id)')
        .inFilter(
          'session_id',
          visible.map((item) => item.session.id!).toList(),
        );
    final participatedIds = <int>{};
    for (final row in rows) {
      final player = row['players'] as Map<String, dynamic>?;
      if (row['profile_id'] == userId || player?['linked_user_id'] == userId) {
        participatedIds.add(row['session_id'] as int);
      }
    }
    return visible
        .where((item) => participatedIds.contains(item.session.id))
        .toList();
  }

  /// Helper to fetch multiple owner display names in one query
  Future<Map<String, String>> _getOwnerNames(List<String> ownerIds) async {
    if (ownerIds.isEmpty) return {};
    final profiles = await _client
        .from('profiles')
        .select('id, display_name')
        .inFilter('id', ownerIds);
    return {
      for (final p in profiles)
        p['id'] as String: p['display_name'] as String? ?? 'Unknown',
    };
  }

  /// List all games visible through hosting, participation, or a current group.
  Future<List<SessionWithOwner>> listAllVisibleSessions() async {
    return _listGamesFromReadModel('visible_games');
  }

  /// List games hosted by or accepted by the current account.
  Future<List<SessionWithOwner>> listMyGames() async {
    return _listGamesFromReadModel('my_games');
  }

  Future<List<SessionWithOwner>> _listGamesFromReadModel(String rpcName) async {
    final userId = _client.auth.currentUser!.id;

    late final List<Map<String, dynamic>> rows;
    try {
      rows = (await _client.rpc(rpcName) as List).cast<Map<String, dynamic>>();
    } on PostgrestException catch (error) {
      if (isMissingBackendRpc(error)) {
        backendCompatibilityFailure(error);
      }
      rethrow;
    }
    final ownerIds = rows
        .map((row) => row['user_id'] as String)
        .where((id) => id != userId)
        .toSet()
        .toList();
    final ownerNames = await _getOwnerNames(ownerIds);

    return rows.map((row) {
      final session = Session.fromMap(row);
      final ownerId = row['user_id'] as String;
      final canHost = session.ledgerVersion == 2
          ? session.currentHostId == userId
          : ownerId == userId;
      return SessionWithOwner(
        session: session,
        ownerName: ownerId == userId
            ? 'You'
            : ownerNames[ownerId] ?? 'Deleted host',
        isOwner: canHost,
      );
    }).toList();
  }

  /// List games in a specific group through the canonical server read model.
  Future<List<SessionWithOwner>> listSessionsInGroup(int groupId) async {
    final userId = _client.auth.currentUser!.id;
    final sessions =
        (await _client.rpc('group_games', params: {'p_group_id': groupId})
                as List)
            .cast<Map<String, dynamic>>();
    final otherOwnerIds = sessions
        .map((s) => s['user_id'] as String)
        .where((id) => id != userId)
        .toSet()
        .toList();
    final ownerNames = await _getOwnerNames(otherOwnerIds);

    final result = <SessionWithOwner>[];
    for (final s in sessions) {
      final ownerId = s['user_id'] as String;
      final session = Session.fromMap(s);
      final canHost = session.ledgerVersion == 2
          ? session.currentHostId == userId
          : ownerId == userId;

      result.add(
        SessionWithOwner(
          session: session,
          ownerName: ownerId == userId
              ? 'You'
              : (ownerNames[ownerId] ?? 'Unknown'),
          isOwner: canHost,
        ),
      );
    }
    return result;
  }

  Future<Session?> getSessionById(int id) async {
    // RLS is the visibility authority for hosted, participated, and group games.
    final data = await _client
        .from('sessions')
        .select()
        .eq('id', id)
        .maybeSingle();
    if (data == null) return null;
    return Session.fromMap(data);
  }

  /// Legacy roster adapter for unfinished version-1 games and history only.
  Future<List<Player>> getAllLegacyPlayers({bool activeOnly = false}) async {
    // Only show players owned by the current user
    var query = _client
        .from('players')
        .select()
        .eq('user_id', _client.auth.currentUser!.id);
    if (activeOnly) {
      query = query.eq('active', true);
    }
    final data = await query.order('name');
    return (data as List).map((e) => Player.fromMap(e)).toList();
  }

  /// Adds a roster participant only to a server-validated legacy game.
  Future<SessionPlayer> addLegacyPlayerToSession({
    required int sessionId,
    required int playerId,
    required int initialBuyInCents,
    required bool paidUpfront,
  }) async {
    final data = await _client
        .from('session_players')
        .insert({
          'session_id': sessionId,
          'player_id': playerId,
          'buy_in_cents_total': initialBuyInCents,
          'paid_upfront': paidUpfront,
        })
        .select()
        .single();
    return SessionPlayer.fromMap(data);
  }

  Future<void> addRebuy({
    required int sessionPlayerId,
    required int amountCents,
  }) async {
    await _client.rpc(
      'add_legacy_rebuy',
      params: {
        'p_session_player_id': sessionPlayerId,
        'p_amount_cents': amountCents,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<List<Map<String, Object?>>> listSessionPlayersWithNames(
    int sessionId,
  ) async {
    final data = await _client
        .from('session_players')
        .select(
          'id, session_id, player_id, buy_in_cents_total, cash_out_cents, paid_upfront, settlement_done, players(name, email, active)',
        )
        .eq('session_id', sessionId)
        .order('id', ascending: true);

    // Transform the nested player data to flat structure
    return (data as List).map((row) {
      final player = row['players'] as Map<String, dynamic>?;
      return {
        'sp_id': row['id'],
        'session_id': row['session_id'],
        'player_id': row['player_id'],
        'buy_in_cents_total': row['buy_in_cents_total'],
        'cash_out_cents': row['cash_out_cents'],
        'paid_upfront': row['paid_upfront'],
        'settlement_done': row['settlement_done'],
        'player_name': player?['name'],
        'player_email': player?['email'],
        'player_active': player?['active'],
      };
    }).toList();
  }

  /// Batch fetch session players for multiple sessions at once (for analytics performance)
  Future<List<Map<String, Object?>>> listSessionPlayersForMultipleSessions(
    List<int> sessionIds,
  ) async {
    if (sessionIds.isEmpty) return [];
    final rows = await _client.rpc(
      'game_participant_totals',
      params: {'p_session_ids': sessionIds},
    );
    return (rows as List)
        .map((row) => Map<String, Object?>.from(row as Map<String, dynamic>))
        .toList();
  }
}
