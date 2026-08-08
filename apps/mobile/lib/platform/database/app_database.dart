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
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');
  }

  void close() => db.close();
}
