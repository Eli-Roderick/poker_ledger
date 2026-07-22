import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MigrationService {
  static const _dbName = 'poker_ledger.db';
  static const _migrationRpc = 'import_legacy_data';

  /// Check if local SQLite database exists (only on mobile)
  static Future<bool> hasLocalData() async {
    if (kIsWeb) return false;

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        final preferences = await SharedPreferences.getInstance();
        if (preferences.getBool(_skipPreferenceKey(userId)) == true) {
          return false;
        }
      }
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

      final playerCount =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM players'),
          ) ??
          0;

      final sessionCount =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM sessions'),
          ) ??
          0;

      final quickAddCount =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM quick_add_entries'),
          ) ??
          0;

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

  /// Imports the complete legacy database through one transactional,
  /// idempotent server RPC and verifies counts plus the financial checksum.
  static Future<MigrationResult> migrateToSupabase() async {
    if (kIsWeb) {
      return MigrationResult(
        success: false,
        error: 'Migration not available on web',
      );
    }

    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;

    if (userId == null) {
      return MigrationResult(success: false, error: 'Not logged in');
    }

    Database? database;
    try {
      final dbPath = await _databasePath();
      database = await openDatabase(dbPath, readOnly: true);
      final payload = await _buildPayload(database);
      final checksum = _checksum(payload);
      final batchId = 'legacy-${checksum.substring(0, 32)}';
      final expectedCounts = _payloadCounts(payload);

      final response = await supabase.rpc(
        _migrationRpc,
        params: {
          'p_batch_id': batchId,
          'p_payload': payload,
          'p_checksum': checksum,
        },
      );
      if (response is! Map) {
        throw const FormatException(
          'Migration server returned an invalid result.',
        );
      }
      final result = Map<String, dynamic>.from(response);
      final returnedChecksum = result['checksum'] as String?;
      final verified = result['verified'] == true;
      final importedCounts = Map<String, dynamic>.from(
        result['counts'] as Map? ?? const {},
      );
      for (final entry in expectedCounts.entries) {
        if (importedCounts[entry.key] != entry.value) {
          throw StateError(
            'Migration verification failed for ${entry.key}: '
            'expected ${entry.value}, received ${importedCounts[entry.key]}.',
          );
        }
      }
      if (!verified || returnedChecksum != checksum) {
        throw StateError('Migration checksum verification failed.');
      }

      await _writeVerificationMarker(
        userId: userId,
        batchId: batchId,
        checksum: checksum,
        counts: expectedCounts,
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_skipPreferenceKey(userId));

      return MigrationResult(
        success: true,
        verified: true,
        batchId: batchId,
        checksum: checksum,
        playersImported: expectedCounts['players']!,
        sessionsImported: expectedCounts['sessions']!,
        sessionPlayersImported: expectedCounts['session_players']!,
        rebuysImported: expectedCounts['rebuys']!,
        quickAddsImported: expectedCounts['quick_add_entries']!,
      );
    } catch (_) {
      return MigrationResult(
        success: false,
        error: 'Migration could not be completed. Your local data was kept.',
      );
    } finally {
      await database?.close();
    }
  }

  /// Deletes local data only after the current database still matches a
  /// server-verified migration marker for the signed-in account.
  static Future<bool> deleteLocalDatabase() async {
    if (kIsWeb) return false;

    Database? database;
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return false;
      final dbPath = await _databasePath();
      final markerFile = File(_verificationMarkerPath(dbPath));
      if (!markerFile.existsSync()) return false;
      final marker = jsonDecode(await markerFile.readAsString());
      if (marker is! Map || marker['user_id'] != userId) return false;

      database = await openDatabase(dbPath, readOnly: true);
      final currentChecksum = _checksum(await _buildPayload(database));
      if (marker['checksum'] != currentChecksum) return false;
      await database.close();
      database = null;

      final file = File(dbPath);
      if (file.existsSync()) {
        file.deleteSync();
      }
      if (markerFile.existsSync()) markerFile.deleteSync();
      return true;
    } catch (e) {
      return false;
    } finally {
      await database?.close();
    }
  }

  /// Lets a user continue without destroying the recoverable local database.
  static Future<void> skipForCurrentUser() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_skipPreferenceKey(userId), true);
  }

  static String _skipPreferenceKey(String userId) =>
      'legacy_migration_skipped:$userId';

  static Future<String> _databasePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _dbName);
  }

  static String _verificationMarkerPath(String dbPath) =>
      '$dbPath.migration_verified.json';

  static Future<void> _writeVerificationMarker({
    required String userId,
    required String batchId,
    required String checksum,
    required Map<String, int> counts,
  }) async {
    final dbPath = await _databasePath();
    final marker = File(_verificationMarkerPath(dbPath));
    await marker.writeAsString(
      jsonEncode({
        'user_id': userId,
        'batch_id': batchId,
        'checksum': checksum,
        'counts': counts,
        'verified_at': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }

  static Future<Map<String, dynamic>> _buildPayload(Database database) async {
    final players = await database.query('players', orderBy: 'id');
    final sessions = await database.query('sessions', orderBy: 'id');
    final sessionPlayers = await database.query(
      'session_players',
      orderBy: 'id',
    );
    final rebuys = await database.query('rebuys', orderBy: 'id');
    final quickAdds = await database.query('quick_add_entries', orderBy: 'id');

    final playerIds = players.map((row) => row['id'] as int).toSet();
    final sessionIds = sessions.map((row) => row['id'] as int).toSet();
    final sessionPlayerIds = sessionPlayers
        .map((row) => row['id'] as int)
        .toSet();
    for (final row in sessionPlayers) {
      if (!sessionIds.contains(row['session_id']) ||
          !playerIds.contains(row['player_id'])) {
        throw StateError(
          'Local game-player ${row['id']} has a missing game or player.',
        );
      }
    }
    for (final row in rebuys) {
      if (!sessionPlayerIds.contains(row['session_player_id'])) {
        throw StateError('Local rebuy ${row['id']} has a missing game player.');
      }
    }
    for (final row in quickAdds) {
      if (!playerIds.contains(row['player_id'])) {
        throw StateError('Local quick add ${row['id']} has a missing player.');
      }
    }

    String? timestamp(Object? value) {
      if (value == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        value as int,
        isUtc: true,
      ).toIso8601String();
    }

    return {
      'source': 'sqlite_v1',
      'players': [
        for (final row in players)
          {
            'source_id': row['id'],
            'name': row['name'],
            'email': row['email'],
            'phone': row['phone'],
            'notes': row['notes'],
            'active': ((row['active'] as int?) ?? 1) == 1,
            'created_at': timestamp(row['created_at']),
          },
      ],
      'sessions': [
        for (final row in sessions)
          {
            'source_id': row['id'],
            'name': row['name'],
            'started_at': timestamp(row['started_at']),
            'ended_at': timestamp(row['ended_at']),
            'finalized': ((row['finalized'] as int?) ?? 0) == 1,
            'settlement_mode': row['settlement_mode'] ?? 'pairwise',
            'banker_source_session_player_id': row['banker_session_player_id'],
          },
      ],
      'session_players': [
        for (final row in sessionPlayers)
          {
            'source_id': row['id'],
            'session_source_id': row['session_id'],
            'player_source_id': row['player_id'],
            'buy_in_cents_total': row['buy_in_cents_total'] ?? 0,
            'cash_out_cents': row['cash_out_cents'],
            'paid_upfront': ((row['paid_upfront'] as int?) ?? 1) == 1,
            'settlement_done': ((row['settlement_done'] as int?) ?? 0) == 1,
          },
      ],
      'rebuys': [
        for (final row in rebuys)
          {
            'source_id': row['id'],
            'session_player_source_id': row['session_player_id'],
            'amount_cents': row['amount_cents'],
            'created_at': timestamp(row['created_at']),
          },
      ],
      'quick_add_entries': [
        for (final row in quickAdds)
          {
            'source_id': row['id'],
            'player_source_id': row['player_id'],
            'amount_cents': row['amount_cents'],
            'note': row['note'],
            'created_at': timestamp(row['created_at']),
          },
      ],
    };
  }

  static Map<String, int> _payloadCounts(Map<String, dynamic> payload) => {
    'players': (payload['players'] as List).length,
    'sessions': (payload['sessions'] as List).length,
    'session_players': (payload['session_players'] as List).length,
    'rebuys': (payload['rebuys'] as List).length,
    'quick_add_entries': (payload['quick_add_entries'] as List).length,
  };

  static String _checksum(Map<String, dynamic> payload) =>
      sha256.convert(utf8.encode(jsonEncode(payload))).toString();
}

class MigrationResult {
  final bool success;
  final bool verified;
  final String? error;
  final String? batchId;
  final String? checksum;
  final int playersImported;
  final int sessionsImported;
  final int sessionPlayersImported;
  final int rebuysImported;
  final int quickAddsImported;

  MigrationResult({
    required this.success,
    this.verified = false,
    this.error,
    this.batchId,
    this.checksum,
    this.playersImported = 0,
    this.sessionsImported = 0,
    this.sessionPlayersImported = 0,
    this.rebuysImported = 0,
    this.quickAddsImported = 0,
  });

  int get totalImported =>
      playersImported +
      sessionsImported +
      sessionPlayersImported +
      rebuysImported +
      quickAddsImported;
}
