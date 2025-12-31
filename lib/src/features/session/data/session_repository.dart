import 'package:sqflite/sqflite.dart';

import '../../../db/app_database.dart';
import '../../players/domain/player.dart';
import '../domain/session_models.dart';

class SessionRepository {
  Future<Database> get _db async => AppDatabase.instance();

  // Create a new session if none open; otherwise return the current open session.
  Future<Session> getOrCreateOpenSession() async {
    final db = await _db;
    final rows = await db.query('sessions', where: 'finalized = 0', orderBy: 'started_at DESC', limit: 1);
    if (rows.isNotEmpty) return Session.fromMap(rows.first);
    final now = DateTime.now();
    final id = await db.insert('sessions', {
      'name': null,
      'started_at': now.millisecondsSinceEpoch,
      'ended_at': null,
      'finalized': 0,
    });
    return Session(id: id, name: null, startedAt: now, endedAt: null, finalized: false);
  }

  Future<void> updateSettlementDone({required int sessionPlayerId, required bool done}) async {
    final db = await _db;
    await db.update(
      'session_players',
      {'settlement_done': done ? 1 : 0},
      where: 'id = ?',
      whereArgs: [sessionPlayerId],
    );
  }

  Future<void> updatePaidUpfront({required int sessionPlayerId, required bool paidUpfront}) async {
    final db = await _db;
    await db.update(
      'session_players',
      {'paid_upfront': paidUpfront ? 1 : 0},
      where: 'id = ?',
      whereArgs: [sessionPlayerId],
    );
  }

  Future<void> setSettlementMode({required int sessionId, required String mode}) async {
    final db = await _db;
    await db.update('sessions', {'settlement_mode': mode}, where: 'id = ?', whereArgs: [sessionId]);
  }

  Future<void> setBanker({required int sessionId, required int? bankerSessionPlayerId}) async {
    final db = await _db;
    await db.update('sessions', {'banker_session_player_id': bankerSessionPlayerId},
        where: 'id = ?', whereArgs: [sessionId]);
  }

  Future<void> updateCashOut({required int sessionPlayerId, required int? cashOutCents}) async {
    final db = await _db;
    await db.update(
      'session_players',
      {'cash_out_cents': cashOutCents},
      where: 'id = ?',
      whereArgs: [sessionPlayerId],
    );
  }

  Future<void> deleteSession(int sessionId) async {
    final db = await _db;
    await db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
  }

  Future<void> deleteSessionPlayer(int sessionPlayerId) async {
    final db = await _db;
    await db.transaction((txn) async {
      // Null out banker if this participant is currently set as banker
      await txn.update(
        'sessions',
        {'banker_session_player_id': null},
        where: 'banker_session_player_id = ?',
        whereArgs: [sessionPlayerId],
      );
      // Remove related rebuys (if FK doesn't cascade)
      await txn.delete('rebuys', where: 'session_player_id = ?', whereArgs: [sessionPlayerId]);
      // Finally remove the participant
      await txn.delete('session_players', where: 'id = ?', whereArgs: [sessionPlayerId]);
    });
  }

  Future<Session> createSession({String? name}) async {
    final db = await _db;
    final now = DateTime.now();
    final id = await db.insert('sessions', {
      'name': name,
      'started_at': now.millisecondsSinceEpoch,
      'ended_at': null,
      'finalized': 0,
    });
    return Session(id: id, name: name, startedAt: now, endedAt: null, finalized: false);
  }

  Future<void> renameSession({required int sessionId, required String? name}) async {
    final db = await _db;
    await db.update('sessions', {'name': name}, where: 'id = ?', whereArgs: [sessionId]);
  }

  Future<void> finalizeSession(int sessionId) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Only update if not already finalized; keep existing ended_at if present.
    await db.rawUpdate(
      'UPDATE sessions SET finalized = 1, ended_at = COALESCE(ended_at, ?) WHERE id = ? AND finalized = 0',
      [now, sessionId],
    );
  }

  Future<List<Session>> listSessions() async {
    final db = await _db;
    final rows = await db.query('sessions', orderBy: 'started_at DESC');
    return rows.map((e) => Session.fromMap(e)).toList();
  }

  Future<Session?> getSessionById(int id) async {
    final db = await _db;
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Session.fromMap(rows.first);
  }

  // Analytics helper: total quick-add cents per player
  Future<List<Map<String, Object?>>> listQuickAddSumsByPlayer() async {
    final db = await _db;
    return db.rawQuery('''
      SELECT qe.player_id, COALESCE(SUM(qe.amount_cents), 0) as total_cents
      FROM quick_add_entries qe
      GROUP BY qe.player_id
    ''');
  }

  Future<List<Player>> getAllPlayers({bool activeOnly = false}) async {
    final db = await _db;
    final rows = await db.query(
      'players',
      where: activeOnly ? 'active = 1' : null,
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map((e) => Player.fromMap(e)).toList();
  }

  Future<SessionPlayer?> getSessionPlayer(int sessionId, int playerId) async {
    final db = await _db;
    final rows = await db.query('session_players',
        where: 'session_id = ? AND player_id = ?', whereArgs: [sessionId, playerId], limit: 1);
    if (rows.isEmpty) return null;
    return SessionPlayer.fromMap(rows.first);
  }

  Future<SessionPlayer> addPlayerToSession({
    required int sessionId,
    required int playerId,
    required int initialBuyInCents,
    required bool paidUpfront,
  }) async {
    final db = await _db;
    final id = await db.insert('session_players', {
      'session_id': sessionId,
      'player_id': playerId,
      'buy_in_cents_total': initialBuyInCents,
      'paid_upfront': paidUpfront ? 1 : 0,
    });
    return SessionPlayer(
      id: id,
      sessionId: sessionId,
      playerId: playerId,
      buyInCentsTotal: initialBuyInCents,
      paidUpfront: paidUpfront,
    );
  }

  Future<void> addRebuy({required int sessionPlayerId, required int amountCents}) async {
    final db = await _db;
    final now = DateTime.now();
    await db.insert('rebuys', {
      'session_player_id': sessionPlayerId,
      'amount_cents': amountCents,
      'created_at': now.millisecondsSinceEpoch,
    });
    // update aggregate total on session_players
    await db.rawUpdate(
      'UPDATE session_players SET buy_in_cents_total = buy_in_cents_total + ? WHERE id = ?',
      [amountCents, sessionPlayerId],
    );
  }

  Future<List<Map<String, Object?>>> listSessionPlayersWithNames(int sessionId) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT sp.id as sp_id, sp.session_id, sp.player_id, sp.buy_in_cents_total, sp.cash_out_cents, sp.paid_upfront, sp.settlement_done,
             p.name as player_name, p.email as player_email, p.active as player_active
      FROM session_players sp
      JOIN players p ON p.id = sp.player_id
      WHERE sp.session_id = ?
      ORDER BY p.name COLLATE NOCASE
    ''', [sessionId]);
    return rows;
  }
}
 
