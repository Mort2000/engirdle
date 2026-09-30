import 'dart:io';

import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/library/application/library_service.dart';
import 'package:engirdle_mobile/features/library/domain/article_install.dart';
import 'package:engirdle_mobile/features/library/infrastructure/library_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/database/migrations.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/translation_dao.dart';
import 'package:flutter_test/flutter_test.dart';

/// v5 → v6: raw-source import support (lightweight-readpack design §11.1).
/// Additive only — existing rows keep validating, catalog installs leave the
/// new base columns NULL, and the unified install writes the raw-source
/// duplicate identity that the confirmation page queries (§6.3).
void main() {
  test('v5 migrates to v6 additively', () {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    expect(db.db.userVersion, kMigrations.length);
    final articleColumns = db.db
        .select("PRAGMA table_info('articles')")
        .map((row) => row['name'] as String)
        .toSet();
    expect(articleColumns, containsAll(['normalized_sha256', 'source_syntax']));
    expect(
      db.db
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'source_imports'",
          )
          .single['name'],
      'source_imports',
    );
    // Catalog-installed rows keep NULL raw-source identity.
    expect(
      db.db
          .select(
            'SELECT COUNT(*) AS n FROM articles '
            'WHERE normalized_sha256 IS NOT NULL OR source_syntax IS NOT NULL',
          )
          .first['n'],
      0,
    );
  });

  test(
    'raw installs write the duplicate identity and are found by §6.3',
    () async {
      final temp = await Directory.systemTemp.createTemp('v6_dupes_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final dao = LibraryDao(db.db);
      final library = LibraryService(
        dao: dao,
        directories: AppDirectories(temp),
        packagedTranslationInstaller: TranslationDao(
          db.db,
        ).installPackagedSetFor,
      );

      ParsedTextBlock paragraph(String text) => ParsedTextBlock(
        blockId: 'block-1',
        order: 0,
        kind: ArticleTextKind.paragraph,
        sentences: [
          SentenceContent(
            sentenceId: 'sentence-1',
            order: 0,
            text: text,
            runs: [ArticleRun(kind: ArticleRunKind.plain, text: text)],
          ),
        ],
      );

      ValidatedArticleImport pasteInstall(
        String articleId,
        String sourceSha,
        String normalizedSha,
      ) => ValidatedArticleImport(
        articleId: articleId,
        revision: 1,
        artifactRevision: 1,
        title: 'Pasted $articleId',
        source: const ArticleSource(),
        origin: 'paste',
        formatVersion: 'local-1',
        sourceSha256: sourceSha,
        normalizedSha256: normalizedSha,
        sourceSyntax: 'plain_text',
        structureSha256: 'e${articleId}f',
        segmenterVersion: 'engirdle-segmenter-dart@3',
        blocks: [paragraph('Hello world.')],
        manifestJson: '{}',
        attributionJson: '{}',
        artifactSizeBytes: 13,
        artifactSha256: sourceSha,
      );

      library.commitInstall(
        pasteInstall('a-paste', 'a'.padRight(64, '0'), 'b'.padRight(64, '0')),
      );

      final exact = library.duplicates(
        sourceSha256: 'a'.padRight(64, '0'),
        normalizedSha256: 'b'.padRight(64, '0'),
        sourceSyntax: 'plain_text',
      );
      expect(exact.exact.map((a) => a.articleId), ['a-paste']);
      expect(exact.content, isEmpty);

      // Same content, different raw bytes (e.g. a BOM'd file): content match.
      library.commitInstall(
        pasteInstall('a-file', 'c'.padRight(64, '0'), 'b'.padRight(64, '0')),
      );
      final contentMatch = library.duplicates(
        sourceSha256: 'd'.padRight(64, '0'),
        normalizedSha256: 'b'.padRight(64, '0'),
        sourceSyntax: 'plain_text',
      );
      expect(contentMatch.exact, isEmpty);
      expect(contentMatch.content.map((a) => a.articleId).toSet(), {
        'a-paste',
        'a-file',
      });

      final installed = dao.getArticle('a-paste')!;
      expect(installed.origin, 'paste');
      expect(installed.formatVersion, 'local-1');
      expect(installed.sourceSyntax, 'plain_text');
      expect(installed.narration, isNull);
      expect(dao.getBlocks('a-paste'), isNotEmpty);
    },
  );
}
