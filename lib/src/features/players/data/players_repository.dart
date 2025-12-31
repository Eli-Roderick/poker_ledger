import 'package:sqflite/sqflite.dart';

import '../../../db/app_database.dart';
import '../domain/player.dart';

class PlayersRepository {
  Future<Database> get _db async => AppDatabase.instance();

  Future<List<Player>> getAll({bool includeDeactivated = false, bool deactivatedOnly = false}) async {
    final db = await _db;
    final where = deactivatedOnly
        ? 'active = 0'
        : (includeDeactivated ? null : 'active = 1');
    final rows = await db.query(
      'players',
      where: where,
      orderBy: 'created_at DESC',
    );
    return rows.map((e) => Player.fromMap(e)).toList();
  }

  Future<Player> add({
    required String name,
    String? email,
    String? phone,
    String? notes,
  }) async {
    final db = await _db;
    final now = DateTime.now();
    final id = await db.insert('players', {
      'name': name,
      'email': email,
      'phone': phone,
      'notes': notes,
      'created_at': now.millisecondsSinceEpoch,
    });
    return Player(
      id: id,
      name: name,
      email: email,
      phone: phone,
      notes: notes,
      createdAt: now,
    );
  }

  Future<void> delete(int id) async {
    final db = await _db;
    await db.delete('players', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setActive({required int id, required bool active}) async {
    final db = await _db;
    await db.update('players', {'active': active ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
  }

  Future<Player> update({
    required int id,
    required String name,
    String? email,
    String? phone,
    String? notes,
  }) async {
    final db = await _db;
    await db.update(
      'players',
      {
        'name': name,
        'email': email,
        'phone': phone,
        'notes': notes,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    final rows = await db.query('players', where: 'id = ?', whereArgs: [id], limit: 1);
    return Player.fromMap(rows.first);
  }
}
