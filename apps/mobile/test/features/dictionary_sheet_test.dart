import 'package:engirdle_mobile/app/theme.dart';
import 'package:engirdle_mobile/features/dictionary/domain/dictionary_models.dart';
import 'package:engirdle_mobile/features/dictionary/presentation/dictionary_sheet.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/vocabulary/application/vocabulary_service.dart';
import 'package:engirdle_mobile/features/vocabulary/infrastructure/vocabulary_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/shared_kernel/content_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows bilingual senses and saves with a compact bookmark', (
    tester,
  ) async {
    final database = AppDatabase.inMemory();
    addTearDown(database.close);
    final vocabulary = VocabularyService(dao: VocabularyDao(database.db));
    DictionarySheet sheet() => DictionarySheet(
      selection: 'mend',
      result: const DictionaryResult(
        surface: 'mend',
        normalized: 'mend',
        senses: [
          DictionarySense(
            senseId: 'oewn-2025/mend-v-1',
            headword: 'mend',
            partOfSpeech: 'verb',
            glossEn: 'to repair something',
            translations: [
              DictionaryTranslation(
                sourceSenseId: 'omw-cmn:2.0/repair-1',
                rawLemma: '修理',
                displayLemma: '修理',
                sourceId: 'omw-cmn:2.0',
              ),
            ],
            sourceId: 'oewn-2025',
            sourceName: 'Open English WordNet 2025',
          ),
        ],
      ),
      resource: _resource,
      article: _article,
      ref: _ref,
      sentenceText: 'He mended the fence.',
      vocabulary: vocabulary,
      onTranslateLocally: () {},
    );

    await tester.pumpWidget(_wrap(sheet()));

    expect(find.text('to repair something'), findsOneWidget);
    expect(find.text('修理'), findsOneWidget);
    expect(find.text('中：'), findsNothing);
    expect(find.text('英英'), findsNothing);
    expect(find.text('英中'), findsNothing);
    expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
    expect(find.text('保存该义项'), findsNothing);

    await tester.tap(find.byIcon(Icons.bookmark_add_outlined));
    await tester.pump();

    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    expect(vocabulary.list(), hasLength(1));
    expect(vocabulary.list().single.senseZh, '修理');

    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    await tester.pumpWidget(_wrap(sheet()));

    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    expect(find.byIcon(Icons.bookmark_add_outlined), findsNothing);
    expect(vocabulary.list(), hasLength(1));
  });

  testWidgets(
    'an English-only sense remains saveable and offers local translation',
    (tester) async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final vocabulary = VocabularyService(dao: VocabularyDao(database.db));
      var translated = false;

      await tester.pumpWidget(
        _wrap(
          DictionarySheet(
            selection: 'mend',
            result: const DictionaryResult(
              surface: 'mend',
              normalized: 'mend',
              senses: [
                DictionarySense(
                  senseId: 'oewn-2025/mend-v-2',
                  headword: 'mend',
                  partOfSpeech: 'verb',
                  glossEn: 'to make amends',
                  sourceId: 'oewn-2025',
                  sourceName: 'Open English WordNet 2025',
                ),
              ],
            ),
            resource: _resource,
            article: _article,
            ref: _ref,
            sentenceText: 'They mended their relationship.',
            vocabulary: vocabulary,
            onTranslateLocally: () => translated = true,
          ),
        ),
      );

      expect(find.text('暂无对译'), findsNothing);
      expect(find.text('本机翻译'), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);

      await tester.tap(find.text('本机翻译'));
      expect(translated, isTrue);
      await tester.tap(find.byIcon(Icons.bookmark_add_outlined));
      await tester.pump();

      expect(vocabulary.list().single.senseEn, 'to make amends');
      expect(vocabulary.list().single.senseZh, isNull);
    },
  );
}

Widget _wrap(Widget child) => PaletteScope(
  palette: AppPalette.paperPreset,
  child: MaterialApp(theme: buildTheme(AppPalette.paperPreset), home: child),
);

const _ref = SentenceRef(
  articleId: '11111111-1111-4111-8111-111111111111',
  revision: 1,
  sentenceId: 's1',
);

final _article = InstalledArticle(
  articleId: _ref.articleId,
  title: 'Article',
  revision: 1,
  artifactRevision: 1,
  packageId: 'package',
  formatVersion: '1.0',
  durationMs: 1000,
  installedAt: DateTime(2026),
);

final _resource = DictionaryResource(
  dictionaryId: 'engirdle-en-zh',
  revision: 2,
  path: '/dictionary.db',
  sizeBytes: 1,
  sha256: '0' * 64,
  databaseSizeBytes: 1,
  databaseSha256: '1' * 64,
  formatVersion: '2.0',
  schemaVersion: 2,
  displayName: 'Engirdle Dictionary',
  generatedAt: '2026-08-09T00:00:00Z',
  builderName: 'test',
  builderVersion: '2.0.0',
  normalizationVersion: 'unicode-nfc-lower-v1',
  sources: [_oewnSource, _omwSource],
  modifications: const [],
  manifestJson: '{}',
);

final _oewnSource = DictionarySource(
  sourceId: 'oewn-2025',
  version: '2025',
  displayName: 'Open English WordNet 2025',
  direction: 'en-en',
  inputUrl: Uri.parse('https://en-word.net/'),
  inputSha256: '0' * 64,
  licenses: const [],
  attributions: const [],
  counts: const DictionarySourceCounts(
    originalHeadwords: 1,
    filteredHeadwords: 0,
    finalHeadwords: 1,
  ),
  extractionNote: 'fixture',
);

final _omwSource = DictionarySource(
  sourceId: 'omw-cmn:2.0',
  version: '2.0',
  displayName: 'Chinese Open Wordnet 2.0',
  direction: 'zh',
  inputUrl: Uri.parse('https://omwn.org/'),
  inputSha256: '1' * 64,
  licenses: const [],
  attributions: const [],
  counts: const DictionarySourceCounts(
    originalHeadwords: 1,
    filteredHeadwords: 0,
    finalHeadwords: 1,
  ),
  extractionNote: 'fixture',
);
