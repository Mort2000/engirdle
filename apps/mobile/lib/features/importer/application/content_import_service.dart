import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../contracts/contract_violation.dart';
import '../../../contracts/readpack_v1/article.dart' show ArticleSource;
import '../../../platform/crypto/sha256.dart';
import '../../../platform/filesystem/app_directories.dart';
import '../../../platform/logging/app_logger.dart';
import '../../../platform/zip/secure_zip_reader.dart';
import '../../../shared_kernel/content_identity.dart';
import '../../../shared_kernel/failures.dart';
import '../../../shared_kernel/id_generator.dart';
import '../../library/application/library_service.dart';
import '../../library/domain/article_install.dart';
import '../../library/domain/installed_article.dart';
import '../../source_ingestion/application/raw_source_parser.dart';
import '../../source_ingestion/domain/raw_source.dart';
import '../../source_ingestion/domain/source_parse_error.dart';
import '../../source_ingestion/infrastructure/markdown_parser.dart';
import '../infrastructure/source_import_dao.dart'
    show SourceImportDao, SourceImportRow, SourceImportState;
import 'import_service.dart';
import 'readpack_router.dart';

/// The input-independent content import module (design §6.5/§7.2) for the
/// raw-source and document ingress. The paste editor and the SAF picker both
/// hand frozen bytes to [stageRawSource] / [importDocumentPackage]; nothing
/// enters the library until the user confirms metadata on the confirmation
/// page, and every step is journaled so process death resumes cleanly.
class ContentImportService {
  ContentImportService({
    required SourceImportDao dao,
    required LibraryService library,
    required AppDirectories directories,
    ReadpackRouter router = const ReadpackRouter(),
    RawSourceParser rawParser = const RawSourceParser(),
    AppLogger? logger,
  }) : _dao = dao,
       _library = library,
       _dirs = directories,
       _router = router,
       _rawParser = rawParser,
       _logger = logger ?? const AppLogger('content-import');

  final SourceImportDao _dao;
  final LibraryService _library;
  final AppDirectories _dirs;
  final ReadpackRouter _router;
  final RawSourceParser _rawParser;
  final AppLogger _logger;

  /// Unconfirmed previews older than this are garbage on [recover] (design
  /// §6.5: awaiting_confirmation 只持有 staging，应设置清理期限).
  static const previewExpiry = Duration(days: 7);

  static const _rawFileNames = {
    SourceSyntax.plainText: 'raw.txt',
    SourceSyntax.markdown: 'raw.md',
  };

  /// Freezes a raw source into staging and the journal, then reports the
  /// preview the confirmation page needs — including duplicate matches
  /// (§6.3). No article exists yet; cancelling drops everything.
  Future<RawSourcePreview> stageRawSource({
    required List<int> rawBytes,
    required SourceSyntax syntax,
    required String origin,
  }) async {
    final importId = newUuid();
    final staging = _dirs.stagingDir(importId);
    await staging.create(recursive: true);
    try {
      var decoded = utf8.decode(rawBytes);
      // Dart's utf8.decode strips a leading BOM; the raw snapshot must hash
      // the user's original bytes, so keep the character in the frozen text
      // (canonicalization strips it again for parsing, §6.1).
      if (rawBytes.length >= 3 &&
          rawBytes[0] == 0xEF &&
          rawBytes[1] == 0xBB &&
          rawBytes[2] == 0xBF &&
          decoded.isNotEmpty &&
          decoded.codeUnitAt(0) != 0xFEFF) {
        decoded = '﻿$decoded';
      }
      final candidate = _rawParser.parsePaste(text: decoded, syntax: syntax);
      await File(
        p.join(staging.path, _rawFileNames[syntax]),
      ).writeAsBytes(rawBytes);
      await File(
        p.join(staging.path, 'canonical.txt'),
      ).writeAsString(candidate.canonical);
      final now = DateTime.now().toUtc().toIso8601String();
      _dao.insert(
        SourceImportRow(
          importId: importId,
          state: SourceImportState.awaitingConfirmation.wire,
          syntax: syntax.wire,
          rawSha256: candidate.sourceSha256,
          normalizedSha256: candidate.normalizedSha256,
          structureSha256: candidate.structureSha256,
          suggestedTitle: candidate.suggestedTitle,
          statsJson: jsonEncode({
            'origin': origin,
            'blocks': candidate.counts.blocks,
            'sentences': candidate.counts.sentences,
            'tables': candidate.counts.tables,
            'code_blocks': candidate.counts.codeBlocks,
            'can_translate': candidate.canTranslate,
          }),
          warningsJson: jsonEncode([
            for (final w in candidate.warnings)
              {'code': w.code, 'block_index': w.blockIndex},
          ]),
          createdAt: now,
          updatedAt: now,
        ),
      );
      return RawSourcePreview(
        importId: importId,
        candidate: candidate,
        duplicates: _duplicatesOf(
          sourceSha256: candidate.sourceSha256,
          normalizedSha256: candidate.normalizedSha256,
          syntax: syntax.wire,
        ),
        origin: origin,
      );
    } on SourceParseException catch (e) {
      await _dropStaging(staging);
      throw AppFailure(FailureKind.packageFormat, 'source rejected: ${e.code}');
    } catch (e) {
      await _dropStaging(staging);
      throw AppFailure(FailureKind.database, 'staging failed', detail: '$e');
    }
  }

  /// The document adapter for raw sources (§6.1): the module — not the
  /// calling widget — owns the extension gate; `.txt`/`.md`/`.markdown`
  /// route to staging, anything else is an actionable error.
  Future<RawSourcePreview> stageDocumentSource({
    required List<int> rawBytes,
    required String fileName,
  }) async {
    final lower = fileName.toLowerCase();
    final supported =
        lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.markdown');
    if (!supported) {
      throw AppFailure(
        FailureKind.packageFormat,
        'unsupported file type "$fileName"; pick .txt, .md or .markdown',
      );
    }
    return stageRawSource(
      rawBytes: rawBytes,
      syntax: SourceSyntax.fromFileName(fileName),
      origin: 'document',
    );
  }

  /// Rebuilds the confirmation preview for a journaled, unconfirmed import
  /// (§6.5/§14.4: kill after 预览 resumes to the confirmation page). The
  /// frozen hashes guard the deterministic re-parse.
  Future<RawSourcePreview> resumePreview(String importId) async {
    final row = _dao.find(importId);
    if (row == null ||
        row.state != SourceImportState.awaitingConfirmation.wire) {
      throw const AppFailure(FailureKind.database, 'no resumable import');
    }
    final syntax = SourceSyntax.fromWire(row.syntax);
    if (syntax == null) {
      throw const AppFailure(FailureKind.database, 'unknown syntax');
    }
    final staging = _dirs.stagingDir(importId);
    final canonicalFile = File(p.join(staging.path, 'canonical.txt'));
    if (!await canonicalFile.exists()) {
      _dao.delete(importId);
      await _dropStaging(staging);
      throw const AppFailure(FailureKind.database, 'staging incomplete');
    }
    final candidate = _rawParser.parsePaste(
      text: await canonicalFile.readAsString(),
      syntax: syntax,
    );
    if (candidate.structureSha256 != row.structureSha256 ||
        candidate.normalizedSha256 != row.normalizedSha256) {
      // The staged snapshot drifted; drop it rather than resume a structure
      // the user never previewed.
      await cancelRawSource(importId);
      throw const AppFailure(
        FailureKind.database,
        'staged structure drifted from the frozen preview',
      );
    }
    return RawSourcePreview(
      importId: importId,
      candidate: candidate,
      // Exact-duplicate identity is the journaled RAW hash (§6.1) — the
      // canonical re-parse would hash different bytes for BOM/CRLF inputs.
      duplicates: _duplicatesOf(
        sourceSha256: row.rawSha256,
        normalizedSha256: row.normalizedSha256,
        syntax: row.syntax,
      ),
      origin: row.stats['origin'] as String? ?? 'paste',
    );
  }

  /// Unconfirmed previews still recoverable after process death.
  List<SourceImportRow> pendingPreviews() => [
    for (final row in _dao.all())
      if (row.state == SourceImportState.awaitingConfirmation.wire) row,
  ];

  /// Cancels an unconfirmed preview: staging and journal row both go away,
  /// never leaving an empty shell article (design §12.2).
  Future<void> cancelRawSource(String importId) async {
    final row = _dao.find(importId);
    if (row == null) return;
    await _dropStaging(_dirs.stagingDir(importId));
    _dao.delete(importId);
  }

  /// Confirms the preview: mints the article identity, writes attribution
  /// from the user's metadata, moves staging into the immutable artifact
  /// directory and commits the install in one journaled sequence.
  Future<ArticleRef> confirmRawSource(
    String importId, {
    required ConfirmedSourceMetadata metadata,
  }) async {
    final row = _dao.find(importId);
    if (row == null) {
      throw const AppFailure(FailureKind.database, 'unknown import');
    }
    if (row.state != SourceImportState.awaitingConfirmation.wire) {
      throw AppFailure(
        FailureKind.database,
        'import not awaiting confirmation (state ${row.state})',
      );
    }
    final syntax = SourceSyntax.fromWire(row.syntax);
    if (syntax == null) {
      throw const AppFailure(FailureKind.database, 'unknown syntax');
    }
    final staging = _dirs.stagingDir(importId);
    final canonicalFile = File(p.join(staging.path, 'canonical.txt'));
    final rawFile = File(p.join(staging.path, _rawFileNames[syntax]));
    if (!await canonicalFile.exists() || !await rawFile.exists()) {
      _dao.delete(importId);
      await _dropStaging(staging);
      throw const AppFailure(FailureKind.database, 'staging incomplete');
    }

    // Deterministic re-parse from the frozen canonical text; the journal's
    // hashes guard against any drift since the preview was frozen (§6.2:
    // 返回修改则废弃旧快照，确认的一定是预览过的结构).
    final candidate = _rawParser.parsePaste(
      text: await canonicalFile.readAsString(),
      syntax: syntax,
    );
    if (candidate.structureSha256 != row.structureSha256 ||
        candidate.normalizedSha256 != row.normalizedSha256) {
      throw const AppFailure(
        FailureKind.database,
        'staged structure drifted from the frozen preview',
      );
    }
    // The re-parse hashes CANONICAL bytes (BOM-stripped, LF) — its
    // sourceSha256 differs from the preview's for BOM/CRLF inputs. The
    // installed source_sha256 must stay the hash of the user's ORIGINAL
    // bytes (§6.1), so verify the staged raw snapshot still matches the
    // journaled hash and record that one (§6.3 exact-duplicate detection
    // depends on it).
    final rawBytes = await rawFile.readAsBytes();
    if (sha256OfBytes(rawBytes) != row.rawSha256) {
      throw const AppFailure(
        FailureKind.database,
        'staged raw source drifted from the frozen preview',
      );
    }

    final articleId = newUuid();
    const revision = 1;
    const artifactRevision = 1;
    final ref = ArticleRef(
      articleId: articleId,
      revision: revision,
      artifactRevision: artifactRevision,
    );
    final origin = row.stats['origin'] as String? ?? 'paste';

    _dao.updateState(importId, SourceImportState.moving.wire);
    // §6.5: the target ref is durable BEFORE the first file moves — a crash
    // between the rename and the DB commit leaves an orphan only recover()
    // can find and roll back.
    _dao.recordMovingTarget(importId, stats: _statsWithTarget(row.stats, ref));
    final attributionJson = _rawAttributionJson(
      title: metadata.title,
      sourceName: metadata.sourceDisplayName,
      sourceUrl: metadata.sourceUrl,
      author: metadata.author,
      licenseName: metadata.licenseName,
    );
    await File(
      p.join(staging.path, 'attribution.json'),
    ).writeAsString(attributionJson);
    // Read before the move takes the staging directory away.
    final install = ValidatedArticleImport(
      articleId: articleId,
      revision: revision,
      artifactRevision: artifactRevision,
      title: metadata.title,
      source: ArticleSource(
        displayName: metadata.sourceDisplayName,
        url: metadata.sourceUrl,
        author: metadata.author,
      ),
      origin: origin,
      formatVersion: 'local-1',
      sourceSha256: row.rawSha256,
      normalizedSha256: candidate.normalizedSha256,
      sourceSyntax: syntax.wire,
      structureSha256: candidate.structureSha256,
      parserVersion: syntax == SourceSyntax.markdown
          ? kDartParserVersion
          : null,
      segmenterVersion: kDartSegmenterVersion,
      blocks: candidate.blocks,
      manifestJson: _syntheticManifestJson(
        importId: importId,
        candidate: candidate,
        syntax: syntax,
        rawSha256: row.rawSha256,
      ),
      attributionJson: attributionJson,
      artifactSizeBytes: rawBytes.length,
      artifactSha256: row.rawSha256,
    );
    await _moveAndCommit(ref: ref, install: install, moveFrom: staging);
    _dao.updateState(importId, SourceImportState.committed.wire);
    _dao.delete(importId);
    _logger.info('content_import.committed', {'article': ref.toString()});
    return ref;
  }

  /// The shared install tail (design §8.2): refuse a live artifact directory,
  /// move the staged content into the immutable location, then switch the DB
  /// pointer — and roll the directory back if the commit fails, since the DB
  /// does not reference it yet.
  Future<void> _moveAndCommit({
    required ArticleRef ref,
    required ValidatedArticleImport install,
    required Directory moveFrom,
  }) async {
    final finalDir = _library.artifactDirectory(ref);
    if (await finalDir.exists()) {
      throw const AppFailure(FailureKind.database, 'artifact already exists');
    }
    await finalDir.parent.create(recursive: true);
    await moveFrom.rename(finalDir.path);
    try {
      _library.commitInstall(install);
    } on AppFailure {
      if (await finalDir.exists()) await finalDir.delete(recursive: true);
      rethrow;
    }
  }

  /// §6.5 pre-extraction gate: the manifest's declared path set must exactly
  /// equal the ZIP's central-directory paths (v2) or the fixed v1 layout,
  /// before any payload beyond the manifest touches the disk.
  void _requireExpectedPaths({
    required String manifestJson,
    required Set<String> entryPaths,
  }) {
    final Object? manifest;
    try {
      manifest = jsonDecode(manifestJson);
    } on FormatException {
      throw const AppFailure(FailureKind.packageFormat, 'invalid manifest');
    }
    if (manifest is! Map<String, Object?>) {
      throw const AppFailure(FailureKind.packageFormat, 'invalid manifest');
    }
    final version = manifest['format_version'];
    final Set<String> expected;
    if (version == '1.0' || version == '1.1') {
      expected = ImportService.allowedPaths;
    } else if (version is String && version.startsWith('2.')) {
      final files = manifest['files'];
      if (files is! List<Object?>) {
        throw const AppFailure(FailureKind.packageFormat, 'invalid manifest');
      }
      expected = {
        for (final f in files)
          if (f is Map<String, Object?> && f['path'] is String)
            f['path']! as String,
        'manifest.json',
      };
    } else {
      throw AppFailure(
        FailureKind.packageFormat,
        'unsupported major version "$version"',
      );
    }
    if (!entryPaths.containsAll(expected) ||
        !expected.containsAll(entryPaths)) {
      throw const AppFailure(
        FailureKind.packageFormat,
        'unexpected package layout',
      );
    }
  }

  /// One-shot import of a SAF-picked `.readpack` (v1 or v2): package content
  /// carries its own metadata, so no confirmation page. Journaled for
  /// recovery like every other ingress.
  Future<ArticleRef> importDocumentPackage({
    required Uint8List bytes,
    String? fileName,
  }) async {
    final importId = newUuid();
    final staging = _dirs.stagingDir(importId);
    await staging.create(recursive: true);
    // §6.5: every ingress journals from the moment its staging exists. The
    // outer hash is the picked package's own bytes; a crash during ZIP
    // extraction or validation is then recoverable (validating → clean up),
    // and the moving target gets recorded before any file moves.
    final now = DateTime.now().toUtc().toIso8601String();
    _dao.insert(
      SourceImportRow(
        importId: importId,
        state: SourceImportState.validating.wire,
        syntax: 'package',
        rawSha256: sha256OfBytes(bytes),
        normalizedSha256: '',
        structureSha256: '',
        suggestedTitle: '',
        statsJson: jsonEncode({
          'origin': 'document',
          'kind': 'readpack',
          'file': fileName ?? '',
        }),
        warningsJson: '[]',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final zipFile = File(p.join(staging.path, 'package.readpack'));
    try {
      await zipFile.writeAsBytes(bytes);
      final entries = await const SecureZipReader().preflight(zipFile);
      // §6.5 order: extract ONLY the bounded manifest first, check the major
      // and the exact path set against the ZIP's central directory, and only
      // then stream the remaining payloads to disk.
      final manifestEntry = entries.firstWhere(
        (e) => e.path == 'manifest.json',
        orElse: () => throw const AppFailure(
          FailureKind.packageFormat,
          'missing manifest.json',
        ),
      );
      final manifestFile = File(p.join(staging.path, 'manifest.json'));
      await const SecureZipReader().extractEntry(
        zipFile,
        manifestEntry,
        manifestFile,
      );
      _requireExpectedPaths(
        manifestJson: await manifestFile.readAsString(),
        entryPaths: {for (final e in entries) e.path},
      );
      final extracted = <String, File>{};
      for (final entry in entries) {
        if (entry.path == 'manifest.json') {
          extracted[entry.path] = manifestFile;
          continue;
        }
        final out = File(p.join(staging.path, entry.path));
        await const SecureZipReader().extractEntry(zipFile, entry, out);
        extracted[entry.path] = out;
      }
      final install = await _router.validate(
        extracted,
        sha256Of: sha256OfFile,
        origin: 'document',
        artifactSizeBytes: bytes.length,
        artifactSha256: sha256OfBytes(bytes),
      );
      final ref = ArticleRef(
        articleId: install.articleId,
        revision: install.revision,
        artifactRevision: install.artifactRevision,
      );
      // Move the extracted payload (not the zip) like every other ingress.
      final payloadDir = Directory(p.join(staging.path, 'payload'));
      await payloadDir.create();
      for (final entry in extracted.entries) {
        final target = File(p.join(payloadDir.path, entry.key));
        await target.parent.create(recursive: true);
        await entry.value.rename(target.path);
      }
      final row = _dao.find(importId)!;
      _dao.updateState(importId, SourceImportState.moving.wire);
      _dao.recordMovingTarget(
        importId,
        stats: _statsWithTarget(row.stats, ref),
      );
      await _moveAndCommit(ref: ref, install: install, moveFrom: payloadDir);
      await _dropStaging(staging);
      _dao.delete(importId);
      _logger.info('content_import.package_committed', {
        'article': ref.toString(),
        'file': fileName ?? '',
      });
      return ref;
    } on ContractViolation catch (e) {
      await _dropStaging(staging);
      _dao.delete(importId);
      throw AppFailure(
        FailureKind.packageFormat,
        'package contract violation',
        detail: '$e',
      );
    } on AppFailure {
      await _dropStaging(staging);
      _dao.delete(importId);
      rethrow;
    } catch (e) {
      await _dropStaging(staging);
      _dao.delete(importId);
      throw AppFailure(
        FailureKind.database,
        'package import failed',
        detail: '$e',
      );
    }
  }

  /// Startup recovery (design §6.5): waiting previews survive if fresh and
  /// are dropped once expired; validating rows never reached the library;
  /// moving/failed rows replay-or-roll-back by their recorded target ref.
  Future<void> recover() async {
    final now = DateTime.now().toUtc();
    for (final row in _dao.all()) {
      try {
        switch (SourceImportState.fromWire(row.state)) {
          case null:
            _logger.warn('content_import.unknown_state', {
              'import_id': row.importId,
              'state': row.state,
            });
            await _dropStaging(_dirs.stagingDir(row.importId));
            _dao.delete(row.importId);
          case SourceImportState.awaitingConfirmation:
            final created = DateTime.parse(row.createdAt);
            if (now.difference(created) > previewExpiry) {
              await cancelRawSource(row.importId);
            }
          case SourceImportState.validating:
            // Extraction/validation never finished: nothing entered the
            // library, only staging needs cleaning.
            await _dropStaging(_dirs.stagingDir(row.importId));
            _dao.delete(row.importId);
          case SourceImportState.moving:
          case SourceImportState.failed:
            await _recoverMoving(row);
          case SourceImportState.committed:
          case SourceImportState.cancelled:
            _dao.delete(row.importId);
        }
      } catch (e) {
        _logger.error('content_import.recover_failed', {
          'import_id': row.importId,
          'error': '$e',
        });
      }
    }
  }

  /// Replay-or-rollback for a move that never recorded its commit (§6.5):
  /// when the library already holds the recorded target, the DB commit
  /// landed and the content stays; otherwise a final artifact directory for
  /// the target is an orphan (files moved, pointer never committed) and is
  /// removed — without this, the next import of the same package would be
  /// blocked by "artifact already exists" forever.
  Future<void> _recoverMoving(SourceImportRow row) async {
    final ref = _targetRefOf(row);
    if (ref != null) {
      final installed = _library.getArticle(ref.articleId);
      final committed =
          installed != null &&
          installed.artifactRevision == ref.artifactRevision;
      if (!committed) {
        final finalDir = _library.artifactDirectory(ref);
        if (await finalDir.exists()) {
          await finalDir.delete(recursive: true);
          _logger.warn('content_import.rolled_back_orphan', {
            'article': ref.toString(),
          });
        }
      }
    }
    await _dropStaging(_dirs.stagingDir(row.importId));
    _dao.delete(row.importId);
  }

  static Map<String, Object?> _statsWithTarget(
    Map<String, Object?> stats,
    ArticleRef ref,
  ) => {
    ...stats,
    'article_ref': {
      'article_id': ref.articleId,
      'revision': ref.revision,
      'artifact_revision': ref.artifactRevision,
    },
  };

  static ArticleRef? _targetRefOf(SourceImportRow row) {
    final raw = row.stats['article_ref'];
    if (raw is! Map) return null;
    final articleId = raw['article_id'];
    final revision = raw['revision'];
    final artifactRevision = raw['artifact_revision'];
    if (articleId is! String || revision is! int || artifactRevision is! int) {
      return null;
    }
    return ArticleRef(
      articleId: articleId,
      revision: revision,
      artifactRevision: artifactRevision,
    );
  }

  ({List<InstalledArticle> exact, List<InstalledArticle> content})
  _duplicatesOf({
    required String sourceSha256,
    required String normalizedSha256,
    required String syntax,
  }) => _library.duplicates(
    sourceSha256: sourceSha256,
    normalizedSha256: normalizedSha256,
    sourceSyntax: syntax,
  );

  Future<void> _dropStaging(Directory staging) async {
    if (await staging.exists()) await staging.delete(recursive: true);
  }

  static String _syntheticManifestJson({
    required String importId,
    required RawSourceCandidate candidate,
    required SourceSyntax syntax,
    required String rawSha256,
  }) => const JsonEncoder.withIndent('  ').convert({
    'format': 'engirdle-local-source',
    'format_version': 'local-1',
    'import_id': importId,
    'syntax': syntax.wire,
    // The raw hash of the user's original bytes, not the canonical text
    // (§6.1) — BOM/CRLF canonicalization never rewrites source identity.
    'source_sha256': rawSha256,
    'normalized_sha256': candidate.normalizedSha256,
    'structure_sha256': candidate.structureSha256,
    'parser': syntax == SourceSyntax.markdown ? kDartParserVersion : null,
    'segmenter': kDartSegmenterVersion,
  });

  static String _rawAttributionJson({
    required String title,
    String? sourceName,
    String? sourceUrl,
    String? author,
    required String licenseName,
  }) => const JsonEncoder.withIndent('  ').convert({
    'format': 'readpack-attribution',
    'format_version': 'local-1',
    'article': null,
    'resources': [
      {
        'resource_id': 'article-source',
        'kind': 'article_source',
        'role': 'content',
        'name': title,
        'source': sourceName == null || sourceName.trim().isEmpty
            ? {'status': 'unknown'}
            : {'status': 'known', 'value': sourceName.trim()},
        'version': {'status': 'not_applicable'},
        'license': licenseName == 'unknown'
            ? {'status': 'unknown'}
            : {'status': 'known', 'name': licenseName},
        'modifications': {
          'status': 'known',
          'value': 'Segmented into sentences and blocks; wording untouched',
        },
        'hashes': <Object?>[],
      },
      {
        'resource_id': 'engirdle-mobile-pipeline',
        'kind': 'software_dependency',
        'role': 'pipeline',
        'name': 'Engirdle mobile',
        'source': {'status': 'known', 'value': 'Engirdle repository'},
        'version': {'status': 'known', 'value': '0.1.0'},
        'license': {'status': 'unknown'},
        'modifications': {'status': 'not_applicable'},
        'hashes': <Object?>[],
      },
    ],
  });
}

/// Everything the confirmation page renders for a frozen preview (§6.3).
class RawSourcePreview {
  const RawSourcePreview({
    required this.importId,
    required this.candidate,
    required this.duplicates,
    required this.origin,
  });

  final String importId;
  final RawSourceCandidate candidate;

  /// Exact (same raw bytes) and content (same normalized hash + syntax)
  /// matches already in the library — the page prompts, never merges.
  final ({List<InstalledArticle> exact, List<InstalledArticle> content})
  duplicates;
  final String origin;
}

/// User-confirmed metadata from the confirmation page (§6.3).
class ConfirmedSourceMetadata {
  const ConfirmedSourceMetadata({
    required this.title,
    required this.licenseName,
    this.author,
    this.sourceDisplayName,
    this.sourceUrl,
  });

  final String title;
  final String licenseName;
  final String? author;
  final String? sourceDisplayName;
  final String? sourceUrl;
}
