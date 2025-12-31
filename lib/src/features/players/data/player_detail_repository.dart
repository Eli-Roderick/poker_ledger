import 'package:sqflite/sqflite.dart';

import '../../../db/app_database.dart';

class PlayerDetailRepository {
  Future<Database> get _db async => AppDatabase.instance();

  Future<void> addQuickAdd({required int playerId, required int amountCents, String? note}) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('quick_add_entries', {
      'player_id': playerId,
      'amount_cents': amountCents,
      'note': note,
      'created_at': now,
    });
  }

  Future<List<Map<String, Object?>>> listQuickAdds(int playerId) async {
    final db = await _db;
    return db.query(
      'quick_add_entries',
      where: 'player_id = ?',
      whereArgs: [playerId],
      orderBy: 'created_at DESC',
    );
  }

  Future<void> deleteQuickAdd(int id) async {
    final db = await _db;
    await db.delete('quick_add_entries', where: 'id = ?', whereArgs: [id]);
  }

  // Each row: { session_id, session_name, started_at, net_cents }
  Future<List<Map<String, Object?>>> listPlayerSessionNets(int playerId) async {
    final db = await _db;
    return db.rawQuery('''
      SELECT s.id as session_id,
             s.name as session_name,
             s.started_at as started_at,
             COALESCE(sp.cash_out_cents, 0) - COALESCE(sp.buy_in_cents_total, 0) as net_cents
      FROM session_players sp
      JOIN sessions s ON s.id = sp.session_id
      WHERE sp.player_id = ?
      ORDER BY s.started_at DESC
    ''', [playerId]);
  }

  Future<int> totalBuyInCents(int playerId) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(sp.buy_in_cents_total), 0) AS total
      FROM session_players sp
      WHERE sp.player_id = ?
    ''', [playerId]);
    final total = rows.isNotEmpty ? (rows.first['total'] as int? ?? 0) : 0;
    return total;
  }
}
