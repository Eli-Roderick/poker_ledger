import 'package:supabase_flutter/supabase_flutter.dart' hide Session;
import '../../players/domain/player.dart';
import '../domain/session_models.dart';

class SessionRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<Session> getOrCreateOpenSession() async {
    final data = await _client
        .from('sessions')
        .select()
        .eq('finalized', false)
        .order('started_at', ascending: false)
        .limit(1)
        .maybeSingle();
    
    if (data != null) return Session.fromMap(data);
    
    final newSession = await _client.from('sessions').insert({
      'user_id': _client.auth.currentUser!.id,
      'name': null,
      'finalized': false,
    }).select().single();
    return Session.fromMap(newSession);
  }

  Future<void> updateSettlementDone({required int sessionPlayerId, required bool done}) async {
    await _client.from('session_players').update({'settlement_done': done}).eq('id', sessionPlayerId);
  }

  Future<void> updatePaidUpfront({required int sessionPlayerId, required bool paidUpfront}) async {
    await _client.from('session_players').update({'paid_upfront': paidUpfront}).eq('id', sessionPlayerId);
  }

  Future<void> setSettlementMode({required int sessionId, required String mode}) async {
    await _client.from('sessions').update({'settlement_mode': mode}).eq('id', sessionId);
  }

  Future<void> setBanker({required int sessionId, required int? bankerSessionPlayerId}) async {
    await _client.from('sessions').update({'banker_session_player_id': bankerSessionPlayerId}).eq('id', sessionId);
  }

  Future<void> updateCashOut({required int sessionPlayerId, required int? cashOutCents}) async {
    await _client.from('session_players').update({'cash_out_cents': cashOutCents}).eq('id', sessionPlayerId);
  }

  Future<void> deleteSession(int sessionId) async {
    await _client.from('sessions').delete().eq('id', sessionId);
  }

  Future<void> deleteSessionPlayer(int sessionPlayerId) async {
    // Clear banker reference first
    await _client.from('sessions').update({'banker_session_player_id': null}).eq('banker_session_player_id', sessionPlayerId);
    // Delete the session player (rebuys will cascade)
    await _client.from('session_players').delete().eq('id', sessionPlayerId);
  }

  Future<Session> createSession({String? name}) async {
    final data = await _client.from('sessions').insert({
      'user_id': _client.auth.currentUser!.id,
      'name': name,
      'finalized': false,
    }).select().single();
    return Session.fromMap(data);
  }

  Future<void> renameSession({required int sessionId, required String? name}) async {
    await _client.from('sessions').update({'name': name}).eq('id', sessionId);
  }

  Future<void> finalizeSession(int sessionId) async {
    await _client.from('sessions').update({
      'finalized': true,
      'ended_at': DateTime.now().toIso8601String(),
    }).eq('id', sessionId).eq('finalized', false);
  }

  Future<List<Session>> listSessions() async {
    final data = await _client.from('sessions').select().order('started_at', ascending: false);
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

  /// Helper to fetch multiple owner display names in one query
  Future<Map<String, String>> _getOwnerNames(List<String> ownerIds) async {
    if (ownerIds.isEmpty) return {};
    final profiles = await _client
        .from('profiles')
        .select('id, display_name')
        .inFilter('id', ownerIds);
    return {
      for (final p in profiles)
        p['id'] as String: p['display_name'] as String? ?? 'Unknown'
    };
  }

  /// List all sessions visible to user (own + shared via groups)
  Future<List<SessionWithOwner>> listAllVisibleSessions() async {
    final userId = _client.auth.currentUser!.id;
    
    // Run parallel queries for better performance
    final results = await Future.wait([
      _client.from('sessions').select('*').eq('user_id', userId).order('started_at', ascending: false),
      _client.from('groups').select('id').eq('owner_id', userId),
      _client.from('group_members').select('group_id').eq('user_id', userId),
    ]);
    
    final ownSessions = results[0] as List;
    final ownedGroups = results[1] as List;
    final memberGroups = results[2] as List;
    
    final groupIds = <int>{
      ...ownedGroups.map((g) => g['id'] as int),
      ...memberGroups.map((g) => g['group_id'] as int),
    };
    
    final List<SessionWithOwner> result = [];
    final Set<int> addedSessionIds = {};
    
    // Add own sessions
    for (final s in ownSessions) {
      result.add(SessionWithOwner(
        session: Session.fromMap(s),
        ownerName: 'You',
        isOwner: true,
      ));
      addedSessionIds.add(s['id'] as int);
    }
    
    // Get shared sessions from groups
    if (groupIds.isNotEmpty) {
      final sharedSessionIds = await _client
          .from('session_groups')
          .select('session_id')
          .inFilter('group_id', groupIds.toList());
      
      final sessionIds = sharedSessionIds
          .map((s) => s['session_id'] as int)
          .where((id) => !addedSessionIds.contains(id))
          .toSet()
          .toList();
      
      if (sessionIds.isNotEmpty) {
        final sharedSessions = await _client
            .from('sessions')
            .select('*')
            .inFilter('id', sessionIds)
            .order('started_at', ascending: false);
        
        // Batch fetch owner names in one query
        final ownerIds = sharedSessions.map((s) => s['user_id'] as String).toSet().toList();
        final ownerNames = await _getOwnerNames(ownerIds);
        
        for (final s in sharedSessions) {
          final ownerId = s['user_id'] as String;
          result.add(SessionWithOwner(
            session: Session.fromMap(s),
            ownerName: ownerNames[ownerId] ?? 'Unknown',
            isOwner: false,
          ));
        }
      }
    }
    
    // Sort by started_at descending
    result.sort((a, b) => b.session.startedAt.compareTo(a.session.startedAt));
    return result;
  }

  /// List sessions in a specific group
  Future<List<SessionWithOwner>> listSessionsInGroup(int groupId) async {
    final userId = _client.auth.currentUser!.id;
    
    final sessionGroups = await _client
        .from('session_groups')
        .select('session_id')
        .eq('group_id', groupId);
    
    final sessionIds = sessionGroups.map((s) => s['session_id'] as int).toList();
    
    if (sessionIds.isEmpty) return [];
    
    final sessions = await _client
        .from('sessions')
        .select('*')
        .inFilter('id', sessionIds)
        .order('started_at', ascending: false);
    
    // Batch fetch owner names (excluding current user)
    final otherOwnerIds = sessions
        .map((s) => s['user_id'] as String)
        .where((id) => id != userId)
        .toSet()
        .toList();
    final ownerNames = await _getOwnerNames(otherOwnerIds);
    
    final result = <SessionWithOwner>[];
    for (final s in sessions) {
      final ownerId = s['user_id'] as String;
      final isOwner = ownerId == userId;
      result.add(SessionWithOwner(
        session: Session.fromMap(s),
        ownerName: isOwner ? 'You' : (ownerNames[ownerId] ?? 'Unknown'),
        isOwner: isOwner,
      ));
    }
    return result;
  }

  Future<Session?> getSessionById(int id) async {
    final data = await _client.from('sessions').select().eq('id', id).maybeSingle();
    if (data == null) return null;
    return Session.fromMap(data);
  }

  /// List sessions where the current user is a linked player (not owner)
  Future<List<SessionWithOwner>> listSessionsAsLinkedPlayer() async {
    final userId = _client.auth.currentUser!.id;
    
    // Get player IDs linked to this user
    final linkedPlayers = await _client
        .from('players')
        .select('id')
        .eq('linked_user_id', userId);
    
    final playerIds = linkedPlayers.map((p) => p['id'] as int).toList();
    
    if (playerIds.isEmpty) return [];
    
    // Get session IDs where these players participated
    final sessionPlayers = await _client
        .from('session_players')
        .select('session_id')
        .inFilter('player_id', playerIds);
    
    final sessionIds = sessionPlayers.map((sp) => sp['session_id'] as int).toSet().toList();
    
    if (sessionIds.isEmpty) return [];
    
    // Get sessions (excluding ones owned by this user)
    final sessions = await _client
        .from('sessions')
        .select('*')
        .inFilter('id', sessionIds)
        .neq('user_id', userId)
        .order('started_at', ascending: false);
    
    // Batch fetch owner names in one query
    final ownerIds = sessions.map((s) => s['user_id'] as String).toSet().toList();
    final ownerNames = await _getOwnerNames(ownerIds);
    
    return sessions.map((s) {
      final ownerId = s['user_id'] as String;
      return SessionWithOwner(
        session: Session.fromMap(s),
        ownerName: ownerNames[ownerId] ?? 'Unknown',
        isOwner: false,
      );
    }).toList();
  }

  Future<List<Map<String, Object?>>> listQuickAddSumsByPlayer() async {
    final data = await _client.from('quick_add_entries').select('player_id, amount_cents');
    
    // Group by player_id and sum
    final Map<int, int> sums = {};
    for (final row in data) {
      final playerId = row['player_id'] as int;
      final amount = row['amount_cents'] as int;
      sums[playerId] = (sums[playerId] ?? 0) + amount;
    }
    
    return sums.entries.map((e) => {'player_id': e.key, 'total_cents': e.value}).toList();
  }

  Future<List<Player>> getAllPlayers({bool activeOnly = false}) async {
    // Only show players owned by the current user
    var query = _client.from('players').select().eq('user_id', _client.auth.currentUser!.id);
    if (activeOnly) {
      query = query.eq('active', true);
    }
    final data = await query.order('name');
    return (data as List).map((e) => Player.fromMap(e)).toList();
  }

  Future<SessionPlayer?> getSessionPlayer(int sessionId, int playerId) async {
    final data = await _client
        .from('session_players')
        .select()
        .eq('session_id', sessionId)
        .eq('player_id', playerId)
        .maybeSingle();
    if (data == null) return null;
    return SessionPlayer.fromMap(data);
  }

  Future<SessionPlayer> addPlayerToSession({
    required int sessionId,
    required int playerId,
    required int initialBuyInCents,
    required bool paidUpfront,
  }) async {
    final data = await _client.from('session_players').insert({
      'session_id': sessionId,
      'player_id': playerId,
      'buy_in_cents_total': initialBuyInCents,
      'paid_upfront': paidUpfront,
    }).select().single();
    return SessionPlayer.fromMap(data);
  }

  Future<void> addRebuy({required int sessionPlayerId, required int amountCents}) async {
    // Insert rebuy
    await _client.from('rebuys').insert({
      'session_player_id': sessionPlayerId,
      'amount_cents': amountCents,
    });
    
    // Get current total and update
    final sp = await _client.from('session_players').select('buy_in_cents_total').eq('id', sessionPlayerId).single();
    final currentTotal = sp['buy_in_cents_total'] as int? ?? 0;
    await _client.from('session_players').update({
      'buy_in_cents_total': currentTotal + amountCents,
    }).eq('id', sessionPlayerId);
  }

  Future<List<Map<String, Object?>>> listSessionPlayersWithNames(int sessionId) async {
    final data = await _client
        .from('session_players')
        .select('id, session_id, player_id, buy_in_cents_total, cash_out_cents, paid_upfront, settlement_done, players(name, email, active)')
        .eq('session_id', sessionId);
    
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
  Future<List<Map<String, Object?>>> listSessionPlayersForMultipleSessions(List<int> sessionIds) async {
    if (sessionIds.isEmpty) return [];
    
    final data = await _client
        .from('session_players')
        .select('id, session_id, player_id, buy_in_cents_total, cash_out_cents, paid_upfront, settlement_done, players(name, email, active, linked_user_id)')
        .inFilter('session_id', sessionIds);
    
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
        'linked_user_id': player?['linked_user_id'],
      };
    }).toList();
  }
}
