import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MigrationService {
  static const _dbName = 'poker_ledger.db';
  
  /// Check if local SQLite database exists (only on mobile)
  static Future<bool> hasLocalData() async {
    if (kIsWeb) return false;
    
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(dir.path, _dbName);
      final file = File(dbPath);
      return file.existsSync();
    } catch (e) {
      return false;
    }
  }
  
  /// Get counts of local data for display
  static Future<Map<String, int>> getLocalDataCounts() async {
    if (kIsWeb) return {};
    
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(dir.path, _dbName);
      final db = await openDatabase(dbPath, readOnly: true);
      
      final playerCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM players')
      ) ?? 0;
      
      final sessionCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM sessions')
      ) ?? 0;
      
      final quickAddCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM quick_add_entries')
      ) ?? 0;
      
      await db.close();
      
      return {
        'players': playerCount,
        'sessions': sessionCount,
        'quickAdds': quickAddCount,
      };
    } catch (e) {
      return {};
    }
  }
  
  /// Migrate all local data to Supabase
  static Future<MigrationResult> migrateToSupabase() async {
    if (kIsWeb) {
      return MigrationResult(success: false, error: 'Migration not available on web');
    }
    
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;
    
    if (userId == null) {
      return MigrationResult(success: false, error: 'Not logged in');
    }
    
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(dir.path, _dbName);
      final db = await openDatabase(dbPath, readOnly: true);
      
      // Track old ID -> new ID mappings
      final Map<int, int> playerIdMap = {};
      final Map<int, int> sessionIdMap = {};
      final Map<int, int> sessionPlayerIdMap = {};
      
      int playersImported = 0;
      int sessionsImported = 0;
      int sessionPlayersImported = 0;
      int rebuysImported = 0;
      int quickAddsImported = 0;
      
      // 1. Migrate players
      final players = await db.query('players');
      for (final player in players) {
        final oldId = player['id'] as int;
        final data = await supabase.from('players').insert({
          'user_id': userId,
          'name': player['name'],
          'email': player['email'],
          'phone': player['phone'],
          'notes': player['notes'],
          'active': ((player['active'] as int?) ?? 1) == 1,
          'created_at': DateTime.fromMillisecondsSinceEpoch(player['created_at'] as int).toIso8601String(),
        }).select('id').single();
        playerIdMap[oldId] = data['id'] as int;
        playersImported++;
      }
      
      // 2. Migrate sessions
      final sessions = await db.query('sessions');
      for (final session in sessions) {
        final oldId = session['id'] as int;
        final data = await supabase.from('sessions').insert({
          'user_id': userId,
          'name': session['name'],
          'started_at': DateTime.fromMillisecondsSinceEpoch(session['started_at'] as int).toIso8601String(),
          'ended_at': session['ended_at'] != null 
              ? DateTime.fromMillisecondsSinceEpoch(session['ended_at'] as int).toIso8601String()
              : null,
          'finalized': ((session['finalized'] as int?) ?? 0) == 1,
          'settlement_mode': session['settlement_mode'] ?? 'pairwise',
        }).select('id').single();
        sessionIdMap[oldId] = data['id'] as int;
        sessionsImported++;
      }
      
      // 3. Migrate session_players
      final sessionPlayers = await db.query('session_players');
      for (final sp in sessionPlayers) {
        final oldId = sp['id'] as int;
        final oldSessionId = sp['session_id'] as int;
        final oldPlayerId = sp['player_id'] as int;
        
        // Skip if session or player wasn't migrated
        if (!sessionIdMap.containsKey(oldSessionId) || !playerIdMap.containsKey(oldPlayerId)) {
          continue;
        }
        
        final data = await supabase.from('session_players').insert({
          'session_id': sessionIdMap[oldSessionId],
          'player_id': playerIdMap[oldPlayerId],
          'buy_in_cents_total': sp['buy_in_cents_total'] ?? 0,
          'cash_out_cents': sp['cash_out_cents'],
          'paid_upfront': ((sp['paid_upfront'] as int?) ?? 1) == 1,
          'settlement_done': ((sp['settlement_done'] as int?) ?? 0) == 1,
        }).select('id').single();
        sessionPlayerIdMap[oldId] = data['id'] as int;
        sessionPlayersImported++;
      }
      
      // 4. Update banker references in sessions
      for (final session in sessions) {
        final oldBankerId = session['banker_session_player_id'] as int?;
        if (oldBankerId != null && sessionPlayerIdMap.containsKey(oldBankerId)) {
          final newSessionId = sessionIdMap[session['id'] as int];
          if (newSessionId != null) {
            await supabase.from('sessions').update({
              'banker_session_player_id': sessionPlayerIdMap[oldBankerId],
            }).eq('id', newSessionId);
          }
        }
      }
      
      // 5. Migrate rebuys
      final rebuys = await db.query('rebuys');
      for (final rebuy in rebuys) {
        final oldSpId = rebuy['session_player_id'] as int;
        if (!sessionPlayerIdMap.containsKey(oldSpId)) continue;
        
        await supabase.from('rebuys').insert({
          'session_player_id': sessionPlayerIdMap[oldSpId],
          'amount_cents': rebuy['amount_cents'],
          'created_at': DateTime.fromMillisecondsSinceEpoch(rebuy['created_at'] as int).toIso8601String(),
        });
        rebuysImported++;
      }
      
      // 6. Migrate quick_add_entries
      final quickAdds = await db.query('quick_add_entries');
      for (final qa in quickAdds) {
        final oldPlayerId = qa['player_id'] as int;
        if (!playerIdMap.containsKey(oldPlayerId)) continue;
        
        await supabase.from('quick_add_entries').insert({
          'user_id': userId,
          'player_id': playerIdMap[oldPlayerId],
          'amount_cents': qa['amount_cents'],
          'note': qa['note'],
          'created_at': DateTime.fromMillisecondsSinceEpoch(qa['created_at'] as int).toIso8601String(),
        });
        quickAddsImported++;
      }
      
      await db.close();
      
      return MigrationResult(
        success: true,
        playersImported: playersImported,
        sessionsImported: sessionsImported,
        sessionPlayersImported: sessionPlayersImported,
        rebuysImported: rebuysImported,
        quickAddsImported: quickAddsImported,
      );
    } catch (e) {
      return MigrationResult(success: false, error: e.toString());
    }
  }
  
  /// Delete local SQLite database after successful migration
  static Future<bool> deleteLocalDatabase() async {
    if (kIsWeb) return false;
    
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(dir.path, _dbName);
      final file = File(dbPath);
      if (file.existsSync()) {
        file.deleteSync();
      }
      return true;
    } catch (e) {
      return false;
    }
  }
}

class MigrationResult {
  final bool success;
  final String? error;
  final int playersImported;
  final int sessionsImported;
  final int sessionPlayersImported;
  final int rebuysImported;
  final int quickAddsImported;
  
  MigrationResult({
    required this.success,
    this.error,
    this.playersImported = 0,
    this.sessionsImported = 0,
    this.sessionPlayersImported = 0,
    this.rebuysImported = 0,
    this.quickAddsImported = 0,
  });
  
  int get totalImported => 
      playersImported + sessionsImported + sessionPlayersImported + rebuysImported + quickAddsImported;
}
