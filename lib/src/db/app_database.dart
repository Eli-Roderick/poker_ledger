import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

class AppDatabase {
  static const _dbName = 'poker_ledger.db';
  static const _dbVersion = 1;

  static Database? _instance;

  static Future<Database> instance() async {
    if (_instance != null) return _instance!;
    
    late final String dbPath;
    late final DatabaseFactory dbFactory;
    
    if (kIsWeb) {
      // Web: use IndexedDB-backed SQLite
      dbFactory = databaseFactoryFfiWeb;
      dbPath = _dbName;
    } else {
      // Mobile: use native SQLite
      dbFactory = databaseFactory;
      final dir = await getApplicationDocumentsDirectory();
      dbPath = p.join(dir.path, _dbName);
    }
    
    _instance = await dbFactory.openDatabase(
      dbPath,
      options: sqflite_common.OpenDatabaseOptions(
        version: _dbVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
        // Players table
        await db.execute('''
          CREATE TABLE players (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT,
            phone TEXT,
            notes TEXT,
            created_at INTEGER NOT NULL,
            active INTEGER NOT NULL DEFAULT 1
          );
        ''');

        // Quick add entries (informal adjustments not tied to sessions)
        await db.execute('''
          CREATE TABLE quick_add_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            player_id INTEGER NOT NULL,
            amount_cents INTEGER NOT NULL,
            note TEXT,
            created_at INTEGER NOT NULL,
            FOREIGN KEY(player_id) REFERENCES players(id) ON DELETE CASCADE
          );
        ''');

        // Sessions
        await db.execute('''
          CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            finalized INTEGER NOT NULL DEFAULT 0,
            settlement_mode TEXT NOT NULL DEFAULT 'pairwise',
            banker_session_player_id INTEGER
          );
        ''');

        // Players participating in a session
        await db.execute('''
          CREATE TABLE session_players (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            player_id INTEGER NOT NULL,
            buy_in_cents_total INTEGER NOT NULL DEFAULT 0,
            cash_out_cents INTEGER,
            paid_upfront INTEGER NOT NULL DEFAULT 1,
            settlement_done INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE,
            FOREIGN KEY(player_id) REFERENCES players(id) ON DELETE CASCADE
          );
        ''');

        // Rebuys during a session (per session_player)
        await db.execute('''
          CREATE TABLE rebuys (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_player_id INTEGER NOT NULL,
            amount_cents INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            FOREIGN KEY(session_player_id) REFERENCES session_players(id) ON DELETE CASCADE
          );
        ''');
      },
      onOpen: (db) async {
        // Ensure tables exist (helpful if DB created before schema bump in dev).
        await db.execute('''
          CREATE TABLE IF NOT EXISTS players (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT,
            phone TEXT,
            notes TEXT,
            created_at INTEGER NOT NULL,
            active INTEGER NOT NULL DEFAULT 1
          );
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS quick_add_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            player_id INTEGER NOT NULL,
            amount_cents INTEGER NOT NULL,
            note TEXT,
            created_at INTEGER NOT NULL,
            FOREIGN KEY(player_id) REFERENCES players(id) ON DELETE CASCADE
          );
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            finalized INTEGER NOT NULL DEFAULT 0,
            settlement_mode TEXT NOT NULL DEFAULT 'pairwise',
            banker_session_player_id INTEGER
          );
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS session_players (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            player_id INTEGER NOT NULL,
            buy_in_cents_total INTEGER NOT NULL DEFAULT 0,
            cash_out_cents INTEGER,
            paid_upfront INTEGER NOT NULL DEFAULT 1,
            settlement_done INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE,
            FOREIGN KEY(player_id) REFERENCES players(id) ON DELETE CASCADE
          );
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS rebuys (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_player_id INTEGER NOT NULL,
            amount_cents INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            FOREIGN KEY(session_player_id) REFERENCES session_players(id) ON DELETE CASCADE
          );
        ''');
        // Best-effort add of cash_out_cents for existing dev DBs. Ignore error if it exists.
        try {
          await db.execute('ALTER TABLE session_players ADD COLUMN cash_out_cents INTEGER');
        } catch (_) {}
        try {
          await db.execute("ALTER TABLE sessions ADD COLUMN settlement_mode TEXT NOT NULL DEFAULT 'pairwise'");
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE sessions ADD COLUMN banker_session_player_id INTEGER');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE sessions ADD COLUMN name TEXT');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE session_players ADD COLUMN settlement_done INTEGER NOT NULL DEFAULT 0');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE players ADD COLUMN active INTEGER NOT NULL DEFAULT 1');
        } catch (_) {}
      },
      // Add migrations in onUpgrade when bumping _dbVersion
      ),
    );
    return _instance!;
  }
}
