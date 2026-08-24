import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:engirdle_mobile/app/dependencies.dart';
import 'package:engirdle_mobile/features/importer/application/content_import_service.dart';
import 'package:engirdle_mobile/features/source_ingestion/domain/raw_source.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:path/path.dart' as p;

import '../helpers/test_helpers.dart';

/// ContentImportService (design §6.5): staging → confirmation → atomic
/// install, journaled for recovery; duplicate prompts (§6.3); one-shot
/// `.readpack` document imports routed by major version.
void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await newTestDependencies();
  });

  test('stage → confirm installs a readable source-only article', () async {
    final preview = await deps.contentImport.stageRawSource(
      rawBytes: utf8.encode('# Title\n\nFirst sentence. Second sentence.'),
      syntax: SourceSyntax.markdown,
      origin: 'paste',
    );
    expect(preview.candidate.suggestedTitle, 'Title');
    expect(preview.duplicates.exact, isEmpty);
    expect(preview.duplicates.content, isEmpty);

    final ref = await deps.contentImport.confirmRawSource(
      preview.importId,
      metadata: _confirmedMetadata(title: 'Confirmed Title'),
    );
    final content = deps.library.getContent(ref.articleId)!;
    expect(content.article.title, 'Confirmed Title');
    expect(content.article.origin, 'paste');
    expect(content.article.formatVersion, 'local-1');
    expect(content.article.structureSha256, preview.candidate.structureSha256);
    expect(content.capabilities.hasTranslation, isFalse);
    expect(content.capabilities.hasNarration, isFalse);
    expect(content.blocks, hasLength(2));

    // Staging and journal are cleaned; the artifact holds the frozen files.
    expect(deps.directories.stagingDir(preview.importId).existsSync(), isFalse);
    final artifactDir = deps.library.artifactDirectory(ref);
    expect(File(p.join(artifactDir.path, 'raw.md')).existsSync(), isTrue);
    expect(
      File(p.join(artifactDir.path, 'canonical.txt')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(artifactDir.path, 'attribution.json')).existsSync(),
      isTrue,
    );
    final attribution =
        jsonDecode(
              deps.library.getAttributionJson(ref.articleId)!.attributionJson,
            )
            as Map<String, Object?>;
    expect(attribution['resources'], isNotEmpty);
  });

  test('cancel drops staging and never creates an article', () async {
    final preview = await deps.contentImport.stageRawSource(
      rawBytes: utf8.encode('Some text. More text.'),
      syntax: SourceSyntax.plainText,
      origin: 'paste',
    );
    await deps.contentImport.cancelRawSource(preview.importId);
    expect(deps.directories.stagingDir(preview.importId).existsSync(), isFalse);
    expect(deps.library.listArticles(), isEmpty);
  });

  test('duplicate content is prompted, never merged', () async {
    final bytes = utf8.encode('Duplicate body. Same words.');
    final first = await deps.contentImport.stageRawSource(
      rawBytes: bytes,
      syntax: SourceSyntax.plainText,
      origin: 'paste',
    );
    await deps.contentImport.confirmRawSource(
      first.importId,
      metadata: _confirmedMetadata(title: 'First'),
    );

    final second = await deps.contentImport.stageRawSource(
      rawBytes: bytes,
      syntax: SourceSyntax.plainText,
      origin: 'document',
    );
    expect(second.duplicates.exact, hasLength(1));
    expect(second.duplicates.exact.single.title, 'First');

    // A BOM'd variant is a content duplicate (§6.3).
    final bommed = await deps.contentImport.stageRawSource(
      rawBytes: Uint8List.fromList([0xEF, 0xBB, 0xBF, ...bytes]),
      syntax: SourceSyntax.plainText,
      origin: 'document',
    );
    expect(bommed.duplicates.exact, isEmpty);
    expect(bommed.duplicates.content, hasLength(1));
    await deps.contentImport.cancelRawSource(bommed.importId);
  });

  test('rejected sources never leave staging or journal rows', () async {
    expect(
      () => deps.contentImport.stageRawSource(
        rawBytes: utf8.encode('<div>html</div>'),
        syntax: SourceSyntax.markdown,
        origin: 'paste',
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(deps.directories.stagingRoot.listSync(), isEmpty);
  });

  test('recovery keeps fresh previews and drops expired ones', () async {
    final fresh = await deps.contentImport.stageRawSource(
      rawBytes: utf8.encode('Fresh preview.'),
      syntax: SourceSyntax.plainText,
      origin: 'paste',
    );
    await deps.contentImport.recover();
    expect(deps.directories.stagingDir(fresh.importId).existsSync(), isTrue);

    final stale = await deps.contentImport.stageRawSource(
      rawBytes: utf8.encode('Stale preview.'),
      syntax: SourceSyntax.plainText,
      origin: 'paste',
    );
    deps.database.db.execute(
      "UPDATE source_imports SET created_at = ? WHERE import_id = ?",
      [
        DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 8))
            .toIso8601String(),
        stale.importId,
      ],
    );
    await deps.contentImport.recover();
    expect(deps.directories.stagingDir(stale.importId).existsSync(), isFalse);
  });

  test('recovery drops a crashed moving row and its staging', () async {
    final preview = await deps.contentImport.stageRawSource(
      rawBytes: utf8.encode('Interrupted import.'),
      syntax: SourceSyntax.plainText,
      origin: 'paste',
    );
    deps.database.db.execute(
      "UPDATE source_imports SET state = 'moving' WHERE import_id = ?",
      [preview.importId],
    );
    await deps.contentImport.recover();
    expect(deps.directories.stagingDir(preview.importId).existsSync(), isFalse);
    expect(deps.library.listArticles(), isEmpty);
  });

  test(
    'a v2 source-only document package installs without derivatives',
    () async {
      final zip = File(
        p.join(
          Directory.current.path,
          '..',
          '..',
          'contracts',
          'readpack',
          'v2',
          'fixtures',
          'valid',
          'source-only.readpack',
        ),
      );
      final ref = await deps.contentImport.importDocumentPackage(
        bytes: zip.readAsBytesSync(),
        fileName: 'source-only.readpack',
      );
      final content = deps.library.getContent(ref.articleId)!;
      expect(content.article.origin, 'document');
      expect(content.article.formatVersion, '2.0');
      expect(content.article.sourceSyntax, 'markdown');
      expect(content.capabilities.hasTranslation, isFalse);
      expect(content.capabilities.hasNarration, isFalse);
      expect(content.article.packageId, isNotNull);
    },
  );

  test('a v2 full document package installs both derivatives', () async {
    final zip = File(
      p.join(
        Directory.current.path,
        '..',
        '..',
        'contracts',
        'readpack',
        'v2',
        'fixtures',
        'valid',
        'full.readpack',
      ),
    );
    final ref = await deps.contentImport.importDocumentPackage(
      bytes: zip.readAsBytesSync(),
      fileName: 'full.readpack',
    );
    final content = deps.library.getContent(ref.articleId)!;
    expect(content.capabilities.hasTranslation, isTrue);
    expect(content.capabilities.hasNarration, isTrue);
    expect(content.article.narration, isNotNull);
    expect(content.sentences.every((s) => s.translationZh != null), isTrue);
    // The audio file moved into the artifact directory.
    expect(File(content.audioFilePath!).existsSync(), isTrue);
  });

  test('a v1 document package still imports through the router', () async {
    final zip = File(
      p.join(
        Directory.current.path,
        '..',
        '..',
        'contracts',
        'readpack',
        'v1',
        'fixtures',
        'valid',
        'minimal.readpack',
      ),
    );
    final ref = await deps.contentImport.importDocumentPackage(
      bytes: zip.readAsBytesSync(),
      fileName: 'minimal.readpack',
    );
    final content = deps.library.getContent(ref.articleId)!;
    expect(content.article.formatVersion, anyOf('1.0', '1.1'));
    expect(content.capabilities.hasTranslation, isTrue);
    expect(content.capabilities.hasNarration, isTrue);
  });

  _reviewFixGroup(() => deps);

  test('contract violations become package-format failures', () async {
    final zip = File(
      p.join(
        Directory.current.path,
        '..',
        '..',
        'contracts',
        'readpack',
        'v2',
        'fixtures',
        'invalid',
        'wrong-hash.readpack',
      ),
    );
    await expectLater(
      deps.contentImport.importDocumentPackage(
        bytes: zip.readAsBytesSync(),
        fileName: 'wrong-hash.readpack',
      ),
      throwsA(
        isA<AppFailure>().having(
          (f) => f.kind,
          'kind',
          FailureKind.packageFormat,
        ),
      ),
    );
    expect(deps.directories.stagingRoot.listSync(), isEmpty);
    expect(deps.library.listArticles(), isEmpty);
  });
}

ConfirmedSourceMetadata _confirmedMetadata({required String title}) =>
    ConfirmedSourceMetadata(
      title: title,
      licenseName: 'unknown',
      author: null,
      sourceDisplayName: null,
      sourceUrl: null,
    );

void _reviewFixGroup(AppDependencies Function() depsOf) {
  group('review fixes', () {
    test('unsupported document extensions reject inside the module', () async {
      final deps = depsOf();
      await expectLater(
        deps.contentImport.stageDocumentSource(
          rawBytes: utf8.encode('x'),
          fileName: 'photo.png',
        ),
        throwsA(
          isA<AppFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.packageFormat,
          ),
        ),
      );
      expect(deps.directories.stagingRoot.listSync(), isEmpty);
    });

    test('a staged preview resumes after simulated process death', () async {
      final deps = depsOf();
      final preview = await deps.contentImport.stageRawSource(
        rawBytes: utf8.encode('Resumable body. Second sentence.'),
        syntax: SourceSyntax.plainText,
        origin: 'paste',
      );
      expect(deps.contentImport.pendingPreviews(), hasLength(1));

      final resumed = await deps.contentImport.resumePreview(preview.importId);
      expect(resumed.importId, preview.importId);
      expect(
        resumed.candidate.structureSha256,
        preview.candidate.structureSha256,
      );

      final ref = await deps.contentImport.confirmRawSource(
        preview.importId,
        metadata: const ConfirmedSourceMetadata(
          title: 'Resumed',
          licenseName: 'unknown',
        ),
      );
      expect(deps.library.getContent(ref.articleId)!.article.title, 'Resumed');
      expect(deps.contentImport.pendingPreviews(), isEmpty);
    });

    test('v2 packages with unexpected layouts reject before payload '
        'extraction', () async {
      final deps = depsOf();
      final zip = File(
        p.join(
          Directory.current.path,
          '..',
          '..',
          'contracts',
          'readpack',
          'v2',
          'fixtures',
          'invalid',
          'undeclared-extra-file.readpack',
        ),
      );
      await expectLater(
        deps.contentImport.importDocumentPackage(
          bytes: zip.readAsBytesSync(),
          fileName: 'undeclared-extra-file.readpack',
        ),
        throwsA(
          isA<AppFailure>().having(
            (f) => f.message,
            'message',
            'unexpected package layout',
          ),
        ),
      );
      expect(deps.directories.stagingRoot.listSync(), isEmpty);
      expect(deps.library.listArticles(), isEmpty);
    });

    test('paste staging enforces the module-level size ceiling', () async {
      final deps = depsOf();
      final huge = 'a' * (8 * 1024 * 1024 + 1);
      await expectLater(
        deps.contentImport.stageRawSource(
          rawBytes: utf8.encode(huge),
          syntax: SourceSyntax.plainText,
          origin: 'paste',
        ),
        throwsA(
          isA<AppFailure>().having(
            (f) => f.message,
            'message',
            contains('source_too_large'),
          ),
        ),
      );
      expect(deps.directories.stagingRoot.listSync(), isEmpty);
    });
  });
}
