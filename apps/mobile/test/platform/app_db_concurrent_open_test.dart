import 'dart:io';
import 'dart:isolate';

import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/database/migrations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reopening a migrated database is a no-op at the latest version', () {
    final dir = Directory.systemTemp.createTempSync('engirdle_db');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/app.db';

    final first = AppDatabase.open(path);
    expect(first.db.userVersion, kMigrations.length);
    first.close();

    // A second engine (background worker, §9.2) opens between UI ticks.
    final second = AppDatabase.open(path);
    expect(second.db.userVersion, kMigrations.length);
    second.close();
  });

  test('concurrent first-open from several engines migrates exactly once',
      () async {
    final dir = Directory.systemTemp.createTempSync('engirdle_db');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/app.db';

    // UI engine and background worker engine booting at the same time on a
    // fresh install: every open must succeed, and whichever connection wins
    // a step must be the only one to run its DDL (§9.2 — user_version is
    // re-checked inside the write-locked transaction).
    await Future.wait([
      for (var i = 0; i < 6; i++)
        Isolate.run(() {
          final db = AppDatabase.open(path);
          final version = db.db.userVersion;
          db.db
            ..execute('BEGIN IMMEDIATE')
            ..execute('COMMIT'); // writers must not be locked out afterwards
          db.close();
          return version;
        }),
    ]).then((versions) {
      expect(versions, everyElement(kMigrations.length));
    });

    final check = AppDatabase.open(path);
    expect(check.db.userVersion, kMigrations.length);
    expect(
      check.db
          .select(
            "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' "
            "AND name = 'translation_jobs'",
          )
          .first['n'],
      1,
    );
    check.close();
  });
}
