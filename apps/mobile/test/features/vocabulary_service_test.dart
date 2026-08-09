import 'package:engirdle_mobile/features/dictionary/domain/dictionary_models.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/vocabulary/application/vocabulary_service.dart';
import 'package:engirdle_mobile/features/vocabulary/infrastructure/vocabulary_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/shared_kernel/content_identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// Vocabulary snapshots (MOB-VOC-001/002): one-step save, snackbar undo, and
/// survival of article deletion (no FK by design, design §3.1).
void main() {
  late AppDatabase appDb;
  late VocabularyService service;

  const sense = DictionarySense(
    senseId: 'test.en/mend#v.1',
    headword: 'mend',
    partOfSpeech: 'verb',
    glossEn: 'to repair something',
    glossZh: '修理',
    sourceId: 'oewn-2025',
    sourceName: 'TestDict',
  );
  const resource = DictionaryResource(
    dictionaryId: 'testdict',
    revision: 3,
    path: '/nonexistent',
    sizeBytes: 1,
    sha256: '0000000000000000000000000000000000000000000000000000000000000000',
    databaseSizeBytes: 1,
    databaseSha256:
        '0000000000000000000000000000000000000000000000000000000000000000',
    formatVersion: '1.0',
    schemaVersion: 1,
    displayName: 'Test Dictionary',
    generatedAt: '2026-08-09T00:00:00Z',
    builderName: 'test',
    builderVersion: '1.0.0',
    normalizationVersion: 'unicode-nfc-casefold-v1',
    sources: [],
    modifications: [],
    manifestJson: '{}',
  );
  const ref = SentenceRef(
    articleId: '11111111-1111-4111-8111-111111111111',
    revision: 1,
    sentenceId: 's1',
  );
  final article = InstalledArticle(
    articleId: ref.articleId,
    title: 'Minimal Contract Article',
    revision: 1,
    artifactRevision: 1,
    packageId: 'pkg',
    formatVersion: '1.0',
    durationMs: 1000,
    installedAt: DateTime(2026),
  );

  setUp(() {
    appDb = AppDatabase.inMemory();
    service = VocabularyService(dao: VocabularyDao(appDb.db));
  });

  tearDown(() => appDb.close());

  test(
    'saveSense persists the chosen sense with the frozen context snapshot',
    () {
      final entry = service.saveSense(
        surface: 'mended',
        normalized: 'mended',
        sense: sense,
        lemma: 'mend',
        resource: resource,
        ref: ref,
        sentenceText: 'He mended the fence.',
        sentenceTranslationZh: '他修好了篱笆。',
        article: article,
      );

      final all = service.list();
      expect(all, hasLength(1));
      final stored = all.single;
      expect(stored.vocabularyId, entry.vocabularyId);
      expect(stored.surface, 'mended');
      expect(stored.lemma, 'mend');
      expect(stored.partOfSpeech, 'verb');
      expect(stored.senseEn, 'to repair something');
      expect(stored.senseZh, '修理');
      expect(stored.dictionaryId, 'testdict');
      expect(stored.dictionaryRevision, 3);
      expect(stored.ref, ref);
      expect(stored.sentenceText, 'He mended the fence.');
      expect(stored.sentenceTranslationZh, '他修好了篱笆。');
      expect(stored.articleTitle, 'Minimal Contract Article');
    },
  );

  test('list is newest-first even within the same millisecond', () {
    service.saveSense(
      surface: 'first',
      normalized: 'first',
      sense: sense,
      resource: resource,
      ref: ref,
      sentenceText: 'one',
      article: article,
    );
    service.saveSense(
      surface: 'second',
      normalized: 'second',
      sense: sense,
      resource: resource,
      ref: ref,
      sentenceText: 'two',
      article: article,
    );
    expect(service.list().map((e) => e.surface), ['second', 'first']);
  });

  test('undoSave removes exactly the just-saved entry', () {
    final entry = service.saveSense(
      surface: 'mend',
      normalized: 'mend',
      sense: sense,
      resource: resource,
      ref: ref,
      sentenceText: 'text',
      article: article,
    );
    service.undoSave(entry.vocabularyId);
    expect(service.list(), isEmpty);
    expect(service.byId(entry.vocabularyId), isNull);
  });

  test('countForArticle counts only the given article', () {
    service.saveSense(
      surface: 'mend',
      normalized: 'mend',
      sense: sense,
      resource: resource,
      ref: ref,
      sentenceText: 'text',
      article: article,
    );
    expect(service.countForArticle(ref.articleId), 1);
    expect(service.countForArticle('another-article'), 0);
  });

  test('snapshots survive article deletion (vocabulary has no article FK)', () {
    final fkRows = appDb.db.select("PRAGMA foreign_key_list('vocabulary')");
    expect(
      fkRows,
      isEmpty,
      reason: 'vocabulary must stay readable after its article is gone',
    );

    service.saveSense(
      surface: 'mend',
      normalized: 'mend',
      sense: sense,
      resource: resource,
      ref: ref,
      sentenceText: 'text',
      article: article,
    );
    // Deleting every article row must not cascade into the vocabulary.
    appDb.db.execute('DELETE FROM articles');
    final all = service.list();
    expect(all, hasLength(1));
    expect(all.single.sentenceText, 'text');
  });
}
