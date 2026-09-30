import 'dart:io';

import '../contract_violation.dart';
import 'article_v2.dart';
import 'derivatives_v2.dart';
import 'manifest_v2.dart';

/// A v2 package that passed every structural, integrity and semantic check
/// the mobile import requires (contracts/readpack/v2 README; full JSON Schema
/// conformance stays PC-side — the shared fixtures pin the overlap).
class ValidatedReadpackV2 {
  const ValidatedReadpackV2({
    required this.manifest,
    required this.article,
    required this.attribution,
    required this.translations,
    required this.narrationBytes,
    this.narration,
  });

  final ReadpackV2Manifest manifest;
  final ArticleV2 article;
  final ReadpackV2Attribution attribution;
  final List<TranslationV2> translations;

  /// Present only with a narration derivative; the audio bytes themselves
  /// live in the extracted file the caller moves.
  final NarrationV2? narration;
  final File? narrationBytes;
}

/// Cross-file validation of an extracted v2 .readpack, in the documented
/// reading order: envelope → container path-set equality → integrity →
/// capabilities → derivative binding (§6.5).
class ReadpackV2Validator {
  const ReadpackV2Validator();

  /// [files] maps every extracted ZIP entry path to its file.
  Future<ValidatedReadpackV2> validate(
    Map<String, File> files, {
    required Future<String> Function(File file) sha256Of,
  }) async {
    // 1. Envelope: the manifest must exist and parse before anything else
    //    trusts it; ZIP-level safety (duplicate paths, traversal, links) was
    //    already enforced by the secure reader preflight.
    final manifestFile = files['manifest.json'];
    if (manifestFile == null || !await manifestFile.exists()) {
      throw const ContractViolation('package', 'missing file "manifest.json"');
    }
    final manifest = ReadpackV2Manifest.parse(
      decodeJsonOrViolation(await manifestFile.readAsString(), 'manifest.json'),
    );

    // 2. Container: the actual path set must equal the declared set plus the
    //    manifest itself — nothing undeclared, nothing missing.
    final declared = manifest.files.map((f) => f.path).toSet();
    final actual = files.keys.toSet();
    final undeclared = actual.difference({...declared, 'manifest.json'});
    if (undeclared.isNotEmpty) {
      throw ContractViolation('package', 'undeclared file(s): $undeclared');
    }
    final missing = declared.difference(actual);
    if (missing.isNotEmpty) {
      throw ContractViolation('package', 'missing declared file(s): $missing');
    }

    // 3. Integrity: byte size and SHA-256 per declared payload.
    for (final entry in manifest.files) {
      final file = files[entry.path]!;
      final size = await file.length();
      if (size != entry.size) {
        throw ContractViolation(
          entry.path,
          'size mismatch: declared ${entry.size}, got $size',
        );
      }
      final hash = await sha256Of(file);
      if (hash != entry.sha256) {
        throw ContractViolation(entry.path, 'sha256 mismatch');
      }
    }

    // 4. Capabilities: this build implements none — unknown tokens reject
    //    before any semantic work (fixture: unknown-capability), which is
    //    also what keeps a future 2.y semantic extension from being silently
    //    misread (COMPATIBILITY.md 未来 2.x).
    if (manifest.requiredCapabilities.isNotEmpty) {
      throw const ContractViolation(
        'manifest.required_capabilities',
        'this build defines no required_capabilities',
      );
    }

    // 5. Base and attribution.
    final article = ArticleV2.parse(
      decodeJsonOrViolation(
        await files['article.json']!.readAsString(),
        'article.json',
      ),
    );
    final attribution = ReadpackV2Attribution.parse(
      decodeJsonOrViolation(
        await files['attribution.json']!.readAsString(),
        'attribution.json',
      ),
    );

    if (manifest.structureSha256 != article.structureSha256) {
      throw const ContractViolation(
        'manifest.content.structure_sha256',
        'manifest and article structure hashes disagree',
      );
    }
    if (article.articleId != manifest.articleId ||
        article.revision != manifest.revision) {
      throw const ContractViolation(
        'article',
        'article id/revision mismatch with manifest',
      );
    }
    if (attribution.articleId != manifest.articleId ||
        attribution.revision != manifest.revision) {
      throw const ContractViolation(
        'attribution',
        'article id/revision mismatch with manifest',
      );
    }

    // 6. Derivative binding: declared descriptors ↔ declared files ↔ content.
    final narrationDescriptor = manifest.narration;
    final audioDeclared = declared.contains('audio/article.m4a');
    if (audioDeclared && narrationDescriptor == null) {
      throw const ContractViolation(
        'manifest.files',
        'audio file declared without a narration derivative',
      );
    }
    if (narrationDescriptor != null && !audioDeclared) {
      throw const ContractViolation(
        'manifest.derivatives.narration',
        'narration derivative without the audio file',
      );
    }

    final translations = <TranslationV2>[];
    for (final descriptor in manifest.translations) {
      if (!declared.contains(descriptor.path)) {
        throw ContractViolation(
          'manifest.derivatives.translations',
          'translation descriptor without its file "${descriptor.path}"',
        );
      }
      final translation = TranslationV2.parse(
        decodeJsonOrViolation(
          await files[descriptor.path]!.readAsString(),
          descriptor.path,
        ),
      );
      if (translation.targetLocale != descriptor.locale) {
        throw ContractViolation(
          descriptor.path,
          'locale mismatch with the manifest descriptor',
        );
      }
      if (translation.structureSha256 != article.structureSha256) {
        throw const ContractViolation(
          'translation.structure_sha256',
          'translation binds a different structure hash',
        );
      }
      if (translation.articleId != article.articleId ||
          translation.revision != article.revision) {
        throw const ContractViolation(
          'translation.article',
          'translation article identity mismatch',
        );
      }
      _requireExactCoverage(
        path: 'translation.sentences',
        expected: article.sentenceCoverage.map((e) => e.$2).toList(),
        actual: translation.sentences.map((s) => s.$1).toList(),
        ordered: true,
      );
      _requireTableCoverage(article, translation);
      translations.add(translation);
    }
    // No translation file may exist without a descriptor.
    for (final path in declared) {
      final isTranslationFile = path.startsWith('derivatives/translation.');
      final declaredByDescriptor = manifest.translations.any(
        (t) => t.path == path,
      );
      if (isTranslationFile && !declaredByDescriptor) {
        throw ContractViolation(
          'package',
          'translation file without a manifest descriptor: $path',
        );
      }
    }

    NarrationV2? narration;
    if (narrationDescriptor != null) {
      if (!declared.contains(narrationDescriptor.path)) {
        throw const ContractViolation(
          'manifest.derivatives.narration',
          'narration descriptor without derivatives/narration.json',
        );
      }
      narration = NarrationV2.parse(
        decodeJsonOrViolation(
          await files[narrationDescriptor.path]!.readAsString(),
          narrationDescriptor.path,
        ),
      );
      if (narration.structureSha256 != article.structureSha256) {
        throw const ContractViolation(
          'narration.structure_sha256',
          'narration binds a different structure hash',
        );
      }
      if (narration.articleId != article.articleId ||
          narration.revision != article.revision) {
        throw const ContractViolation(
          'narration.article',
          'narration article identity mismatch',
        );
      }
      // Narration covers exactly the narratable plan: non-empty, monotonic,
      // non-overlapping ranges; millisecond boundaries derive from samples.
      _requireExactCoverage(
        path: 'narration.sentences',
        expected: article.sentenceCoverage.map((e) => e.$2).toList(),
        actual: narration.ranges.map((r) => r.sentenceId).toList(),
        ordered: true,
      );
      var previousEndSample = 0;
      final rate = narration.sampleRateHz;
      for (final range in narration.ranges) {
        if (range.endSample <= range.startSample) {
          throw ContractViolation(
            'narration.sentences(${range.sentenceId})',
            'empty sample range',
          );
        }
        if (range.endMs <= range.startMs) {
          throw ContractViolation(
            'narration.sentences(${range.sentenceId})',
            'empty millisecond range',
          );
        }
        if (range.startMs != (range.startSample * 1000) ~/ rate) {
          throw ContractViolation(
            'narration.sentences(${range.sentenceId})',
            'start ms is not floor(start_sample * 1000 / $rate)',
          );
        }
        if (range.endMs != (range.endSample * 1000 + rate - 1) ~/ rate) {
          throw ContractViolation(
            'narration.sentences(${range.sentenceId})',
            'end ms is not ceil(end_sample * 1000 / $rate)',
          );
        }
        if (range.startSample < previousEndSample) {
          throw ContractViolation(
            'narration.sentences(${range.sentenceId})',
            'overlapping range',
          );
        }
        if (range.endMs > narration.durationMs) {
          throw ContractViolation(
            'narration.sentences(${range.sentenceId})',
            'range exceeds audio duration',
          );
        }
        previousEndSample = range.endSample;
      }
    }

    // 7. Attribution roles conditional on the derivatives actually present.
    attribution.requireDerivativeAttribution(
      translationPresent: translations.isNotEmpty,
      narrationPresent: narration != null,
    );

    return ValidatedReadpackV2(
      manifest: manifest,
      article: article,
      attribution: attribution,
      translations: translations,
      narration: narration,
      narrationBytes: narration == null ? null : files['audio/article.m4a'],
    );
  }

  static void _requireExactCoverage({
    required String path,
    required List<String> expected,
    required List<String> actual,
    required bool ordered,
  }) {
    if (ordered) {
      var mismatch = -1;
      for (var i = 0; i < expected.length && i < actual.length; i++) {
        if (expected[i] != actual[i]) {
          mismatch = i;
          break;
        }
      }
      if (mismatch >= 0) {
        throw ContractViolation(
          path,
          'position $mismatch: expected "${expected[mismatch]}", '
          'got "${actual[mismatch]}"',
        );
      }
      if (expected.length != actual.length) {
        throw ContractViolation(
          path,
          'expected ${expected.length} entries, got ${actual.length}',
        );
      }
      return;
    }
    final expectedSet = expected.toSet();
    final actualSet = actual.toSet();
    final missing = expectedSet.difference(actualSet);
    final extra = actualSet.difference(expectedSet);
    if (missing.isNotEmpty || extra.isNotEmpty) {
      throw ContractViolation(
        path,
        'coverage mismatch — missing: $missing, extra: $extra',
      );
    }
  }

  static void _requireTableCoverage(ArticleV2 article, TranslationV2 t) {
    final baseCells = article.cellCoverageByBlock;
    final translatedBlocks = t.tables.map((entry) => entry.$1).toSet();
    final baseTables = baseCells.keys.toSet();
    if (!translatedBlocks.containsAll(baseTables) ||
        !baseTables.containsAll(translatedBlocks)) {
      throw const ContractViolation(
        'translation.tables',
        'translated table blocks must match the base tables',
      );
    }
    for (final (blockId, cells) in t.tables) {
      final expected = baseCells[blockId]!;
      final actual = cells.map((c) => c.$1).toList();
      if (actual.length != expected.length) {
        throw ContractViolation(
          'translation.tables($blockId)',
          'expected ${expected.length} cells, got ${actual.length}',
        );
      }
      for (var i = 0; i < expected.length; i++) {
        if (expected[i] != actual[i]) {
          throw ContractViolation(
            'translation.tables($blockId)',
            'cell order mismatch at $i: expected "${expected[i]}", '
                'got "${actual[i]}"',
          );
        }
      }
    }
  }
}
