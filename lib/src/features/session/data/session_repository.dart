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

  /// List all sessions visible to user (own + shared via groups)
  Future<List<SessionWithOwner>> listAllVisibleSessions() async {
    final userId = _client.auth.currentUser!.id;
    
    // Get user's own sessions
    final ownSessions = await _client
        .from('sessions')
        .select('*, profiles(display_name)')
        .eq('user_id', userId)
        .order('started_at', ascending: false);
    
    // Get sessions shared to groups user is in
    // First get group IDs user belongs to
    final ownedGroups = await _client
        .from('groups')
        .select('id')
        .eq('owner_id', userId);
    
    final memberGroups = await _client
        .from('group_members')
        .select('group_id')
        .eq('user_id', userId);
    
    final groupIds = <int>{
      ...ownedGroups.map((g) => g['id'] as int),
      ...memberGroups.map((g) => g['group_id'] as int),
    };
    
    final List<SessionWithOwner> result = [];
    final Set<int> addedSessionIds = {};
    
    // Add own sessions
    for (final s in ownSessions) {
      final profile = s['profiles'] as Map<String, dynamic>?;
      result.add(SessionWithOwner(
        session: Session.fromMap(s),
        ownerName: profile?['display_name'] as String? ?? 'You',
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
            .select('*, profiles(display_name)')
            .inFilter('id', sessionIds)
            .order('started_at', ascending: false);
        
        for (final s in sharedSessions) {
          final profile = s['profiles'] as Map<String, dynamic>?;
          result.add(SessionWithOwner(
            session: Session.fromMap(s),
            ownerName: profile?['display_name'] as String? ?? 'Unknown',
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
        .select('*, profiles(display_name)')
        .inFilter('id', sessionIds)
        .order('started_at', ascending: false);
    
    return (sessions as List).map((s) {
      final profile = s['profiles'] as Map<String, dynamic>?;
      return SessionWithOwner(
        session: Session.fromMap(s),
        ownerName: profile?['display_name'] as String? ?? 'Unknown',
        isOwner: s['user_id'] == userId,
      );
    }).toList();
  }

  Future<Session?> getSessionById(int id) async {
    final data = await _client.from('sessions').select().eq('id', id).maybeSingle();
    if (data == null) return null;
    return Session.fromMap(data);
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
    var query = _client.from('players').select();
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
}
