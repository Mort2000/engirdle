import 'dart:io' as io;

import 'package:sqlite3/sqlite3.dart';

import 'migrations.dart';

/// Central entry point for the application database.
///
/// One SQLite file, one ordered migration chain (PRAGMA user_version).
/// Feature DAOs receive the opened [Database] and only touch tables they own
/// (data ownership per module architecture §6.5).
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  /// Opens (and migrates) the database at [path].
  static AppDatabase open(String path) {
    final db = sqlite3.open(path);
    _configure(db);
    migrate(db);
    return AppDatabase._(db);
  }

  /// In-memory database for unit tests.
  static AppDatabase inMemory() {
    final db = sqlite3.openInMemory();
    _configure(db);
    migrate(db);
    return AppDatabase._(db);
  }

  static void _configure(Database db) {
    // busy_timeout first: the UI engine and the background worker engine
    // open concurrently (§9.2), and without it even WAL setup fails with
    // SQLITE_BUSY while the other connection migrates. Writers then wait
    // briefly for each other; WAL keeps readers lock-free.
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('PRAGMA foreign_keys = ON');
    _ensureWal(db);
  }

  /// WAL is persistent in the file, so this only races on the very first
  /// open of a fresh install, when another engine may be mid-migration.
  /// journal_mode changes return SQLITE_BUSY immediately (bypassing the
  /// busy handler) while another connection holds a write transaction, so
  /// retry briefly; whichever engine wins the race persists WAL for both.
  static void _ensureWal(Database db) {
    for (var attempt = 0;; attempt++) {
      final mode = db.select('PRAGMA journal_mode').first.values.first;
      if ('$mode'.toLowerCase().startsWith('wal')) return;
      try {
        db.execute('PRAGMA journal_mode = WAL');
        return;
      } on SqliteException catch (error) {
        // Match the migrations busy-retry budget: heavily loaded parallel
        // first-opens (CI) can stretch the conversion window.
        if (attempt >= 200 || !error.message.contains('locked')) rethrow;
        io.sleep(const Duration(milliseconds: 25));
      }
    }
  }

  void close() => db.close();
}
