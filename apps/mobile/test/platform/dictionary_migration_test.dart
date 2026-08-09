import 'dart:io';

import 'package:engirdle_mobile/features/dictionary/infrastructure/dictionary_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'v1 newest resource migrates once to an explicit active pointer',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'dictionary_migration_',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final path = p.join(temp.path, 'app.db');
      final legacy = sqlite3.open(path);
      legacy.execute('''
      CREATE TABLE dictionary_manifest (
        dictionary_id TEXT PRIMARY KEY,
        revision INTEGER NOT NULL,
        path TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        meta_json TEXT NOT NULL,
        installed_at TEXT NOT NULL
      )
    ''');
      legacy.execute(
        'INSERT INTO dictionary_manifest VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          'older',
          1,
          '/older.db',
          1,
          '0' * 64,
          '{"display_name":"Older"}',
          '2026-08-08T00:00:00Z',
        ],
      );
      legacy.execute(
        'INSERT INTO dictionary_manifest VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          'newer',
          2,
          '/newer.db',
          2,
          '1' * 64,
          '{"display_name":"Newer"}',
          '2026-08-09T00:00:00Z',
        ],
      );
      legacy.userVersion = 1;
      legacy.close();

      final migrated = AppDatabase.open(path);
      addTearDown(migrated.close);
      final dao = DictionaryManifestDao(migrated.db);
      expect(dao.current()!.dictionaryId, 'newer');

      migrated.db.execute(
        "UPDATE dictionary_manifest SET installed_at = '2030-01-01T00:00:00Z' "
        "WHERE dictionary_id = 'older'",
      );

      expect(
        dao.current()!.dictionaryId,
        'newer',
        reason: 'current must come from dictionary_active, never timestamps',
      );
    },
  );
}
