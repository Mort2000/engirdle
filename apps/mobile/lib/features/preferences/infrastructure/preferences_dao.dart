import 'package:sqlite3/sqlite3.dart';

/// DAO for the `preferences` key-value table (owned by preferences).
class PreferencesDao {
  const PreferencesDao(this._db);

  final Database _db;

  String? get(String key) {
    final rows =
        _db.select('SELECT value FROM preferences WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  void set(String key, String value) {
    _db.execute(
      'INSERT INTO preferences (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }
}
