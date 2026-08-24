import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:engirdle_mobile/app/dependencies.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/importer/application/content_import_service.dart';
import 'package:engirdle_mobile/features/library/application/library_service.dart';
import 'package:engirdle_mobile/features/library/domain/article_install.dart';
import 'package:engirdle_mobile/features/source_ingestion/application/raw_source_parser.dart';
import 'package:engirdle_mobile/features/source_ingestion/domain/raw_source.dart';
import 'package:engirdle_mobile/features/source_ingestion/infrastructure/markdown_parser.dart';
import 'package:engirdle_mobile/shared_kernel/content_identity.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:engirdle_mobile/app/scope.dart';
import 'package:engirdle_mobile/app/theme.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/readpack_validator.dart';
import 'package:engirdle_mobile/features/playback/application/audio_focus_port.dart';
import 'package:engirdle_mobile/features/playback/application/playback_driver.dart';
import 'package:engirdle_mobile/platform/crypto/sha256.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:engirdle_mobile/platform/http/lan_http_client.dart';
import 'package:engirdle_mobile/platform/translation/local_text_translator.dart';
import 'package:engirdle_mobile/platform/zip/secure_zip_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Repository-root contracts directory (tests run with CWD = apps/mobile).
final contractsRoot = Directory(
  p.normalize(p.join(Directory.current.path, '..', '..', 'contracts')),
);

File readpackFixture(String relative) =>
    File(p.join(contractsRoot.path, 'readpack', 'v1', 'fixtures', relative));

File catalogFixture(String relative) =>
    File(p.join(contractsRoot.path, 'catalog', 'v1', 'fixtures', relative));

File dictionaryV2Fixture(String relative) =>
    File(p.join(contractsRoot.path, 'dictionary', 'v2', 'fixtures', relative));

/// Extracts [zipFile] with the production reader into a fresh temp directory
/// and runs full cross-file validation.
Future<ValidatedReadpack> extractAndValidate(File zipFile) async {
  final temp = await Directory.systemTemp.createTemp('readpack_contract_');
  addTearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  const reader = SecureZipReader();
  final entries = await reader.preflight(zipFile);
  for (final entry in entries) {
    await reader.extractEntry(
      zipFile,
      entry,
      File(p.join(temp.path, entry.path)),
    );
  }
  final files = {
    for (final path in ReadpackValidator.requiredPaths)
      path: File(p.join(temp.path, path)),
  };
  return const ReadpackValidator().validate(files, sha256Of: sha256OfFile);
}

/// Parses the manifest of a `.readpack` fixture without full validation.
Future<ReadpackManifest> manifestOf(File zipFile) async {
  final temp = await Directory.systemTemp.createTemp('readpack_manifest_');
  addTearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  const reader = SecureZipReader();
  final entries = await reader.preflight(zipFile);
  final manifestEntry = entries.firstWhere((e) => e.path == 'manifest.json');
  final out = File(p.join(temp.path, 'manifest.json'));
  await reader.extractEntry(zipFile, manifestEntry, out);
  return ReadpackManifest.parse(jsonDecode(await out.readAsString()));
}

/// No-op playback driver for unit/widget tests (just_audio is unavailable
/// under `flutter test`). It never emits, so the coordinator stays idle.
class FakePlaybackDriver implements PlaybackDriver {
  final _events = StreamController<PlaybackDriverEvent>.broadcast();

  @override
  Future<void> playClip({
    required String filePath,
    required Duration start,
    required Duration end,
  }) async {}

  @override
  Future<void> playFrom({
    required String filePath,
    required Duration start,
  }) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<PlaybackDriverEvent> get events => _events.stream;

  @override
  Future<void> dispose() async => _events.close();
}

/// No-op focus port for widget tests (the real AudioSessionAdapter touches the
/// platform). Emits nothing, so the coordinator never reacts to interruptions.
class FakeAudioFocusPort implements AudioFocusPort {
  @override
  Stream<AudioFocusEvent> get events => const Stream<AudioFocusEvent>.empty();
  @override
  Future<bool> acquireFocus(AudioFocusMode mode) async => true;
  @override
  Future<void> releaseFocus() async {}
}

/// Builds a full dependency graph on an in-memory database and a temp data
/// directory. Disposal and temp cleanup are registered automatically.
Future<AppDependencies> newTestDependencies({
  PlaybackDriver? driver,
  LanHttpClient? httpClient,
  LocalTextTranslator localTextTranslator = const _FakeLocalTextTranslator(),
}) async {
  final temp = await Directory.systemTemp.createTemp('engirdle_test_');
  final deps = await AppDependencies.build(
    directories: AppDirectories(temp),
    database: AppDatabase.inMemory(),
    driver: driver ?? FakePlaybackDriver(),
    focusPort: FakeAudioFocusPort(),
    httpClient: httpClient ?? LanHttpClient(),
    localTextTranslator: localTextTranslator,
  );
  addTearDown(() async {
    await deps.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  return deps;
}

class _FakeLocalTextTranslator implements LocalTextTranslator {
  const _FakeLocalTextTranslator();

  @override
  Future<LocalTranslationResult> translate(String text) async =>
      LocalTranslationResult.opened;
}

/// Wraps a page with the app scope, palette and theme it expects.
Widget wrapTestWidget(AppDependencies deps, Widget child) {
  const palette = AppPalette.paperPreset;
  return AppScope(
    dependencies: deps,
    child: PaletteScope(
      palette: palette,
      child: MaterialApp(theme: buildTheme(palette), home: child),
    ),
  );
}

/// In-memory ContentImportService for widget tests: real parsing and DB
/// commits, zero filesystem IO (testWidgets' FakeAsync never advances real
/// IO, so the production staging writes must not run under `flutter test`).
class FakeContentImportService implements ContentImportService {
  final Map<String, RawSourceCandidate> _pending = {};
  LibraryService? library;
  var _counter = 0;

  @override
  Future<RawSourcePreview> stageRawSource({
    required List<int> rawBytes,
    required SourceSyntax syntax,
    required String origin,
  }) async {
    final candidate = RawSourceParser().parsePaste(
      text: utf8.decode(rawBytes),
      syntax: syntax,
    );
    final importId = 'fake-import-${_counter++}';
    _pending[importId] = candidate;
    return RawSourcePreview(
      importId: importId,
      candidate: candidate,
      duplicates: (exact: const [], content: const []),
      origin: origin,
    );
  }

  @override
  Future<void> cancelRawSource(String importId) async {
    _pending.remove(importId);
  }

  @override
  Future<ArticleRef> confirmRawSource(
    String importId, {
    required ConfirmedSourceMetadata metadata,
  }) async {
    final candidate = _pending.remove(importId);
    if (candidate == null) {
      throw const AppFailure(FailureKind.database, 'unknown import');
    }
    final articleId = 'fake-article-${_counter++}';
    library!.commitInstall(
      ValidatedArticleImport(
        articleId: articleId,
        revision: 1,
        artifactRevision: 1,
        title: metadata.title,
        source: ArticleSource(
          displayName: metadata.sourceDisplayName,
          url: metadata.sourceUrl,
          author: metadata.author,
        ),
        origin: 'paste',
        formatVersion: 'local-1',
        sourceSha256: candidate.sourceSha256,
        normalizedSha256: candidate.normalizedSha256,
        sourceSyntax: candidate.syntax.wire,
        structureSha256: candidate.structureSha256,
        parserVersion: candidate.syntax == SourceSyntax.markdown
            ? kDartParserVersion
            : null,
        segmenterVersion: kDartSegmenterVersion,
        blocks: candidate.blocks,
        manifestJson: '{}',
        attributionJson: '{}',
        artifactSizeBytes: 0,
        artifactSha256: candidate.sourceSha256,
      ),
    );
    return ArticleRef(articleId: articleId, revision: 1, artifactRevision: 1);
  }

  @override
  Future<ArticleRef> importDocumentPackage({
    required Uint8List bytes,
    String? fileName,
  }) => throw UnimplementedError('not needed in widget tests');

  @override
  Future<void> recover() async {}
}

/// Builds dependencies with the in-memory content import service (widget
/// tests only; plain tests use the real service).
Future<AppDependencies> newWidgetTestDependencies() async {
  final fake = FakeContentImportService();
  final temp = await Directory.systemTemp.createTemp('engirdle_widget_');
  final deps = await AppDependencies.build(
    directories: AppDirectories(temp),
    database: AppDatabase.inMemory(),
    focusPort: FakeAudioFocusPort(),
    driver: FakePlaybackDriver(),
    contentImport: fake,
  );
  fake.library = deps.library;
  addTearDown(() async {
    await deps.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  return deps;
}
