import 'dart:convert';
import 'dart:io';

import '../contract_violation.dart';
import 'article.dart';
import 'attribution.dart';
import 'manifest.dart';

/// A package that passed every v1 structural, reference and hash check.
class ValidatedReadpack {
  const ValidatedReadpack({
    required this.manifest,
    required this.article,
    required this.attribution,
  });

  final ReadpackManifest manifest;
  final ArticleContent article;
  final ReadpackAttribution attribution;
}

/// Cross-file validation of an extracted .readpack (design §6.4):
///
/// - all three JSON documents parse against the v1 schemas (the parsers are
///   the schema layer: block ids unique, orders contiguous from 0, sentence
///   ids unique, v1.0 never carries v1.1 kinds, table/code payload shape);
/// - article identity is consistent across manifest / article / attribution;
/// - every declared file exists with matching size and SHA-256;
/// - manifest and article agree on format_version and required_capabilities,
///   and only known capabilities are declared (markdown-blocks today);
/// - narratable sentences carry a translation, non-empty runs concatenating
///   to the text, and legal, monotonic, non-overlapping audio ranges;
/// - table translation maps cover exactly the table's cell ids;
/// - the article as a whole has at least one narratable sentence.
class ReadpackValidator {
  const ReadpackValidator();

  /// The capabilities this build understands; anything else must be rejected
  /// before the package is trusted (COMPATIBILITY.md v1.1).
  static const knownCapabilities = {'markdown-blocks'};

  static const requiredPaths = [
    'manifest.json',
    'article.json',
    'attribution.json',
    'audio/article.m4a',
  ];

  /// [files] maps logical package paths to extracted files. [sha256Of]
  /// computes a file's hex SHA-256 (injected for tests).
  Future<ValidatedReadpack> validate(
    Map<String, File> files, {
    required Future<String> Function(File file) sha256Of,
  }) async {
    for (final path in requiredPaths) {
      final file = files[path];
      if (file == null || !await file.exists()) {
        throw ContractViolation('package', 'missing file "$path"');
      }
    }

    final manifestBytes = await files['manifest.json']!.readAsBytes();
    final articleBytes = await files['article.json']!.readAsBytes();
    final attributionBytes = await files['attribution.json']!.readAsBytes();

    final manifest = ReadpackManifest.parse(_decodeJson(manifestBytes, 'manifest.json'));
    final article = ArticleContent.parse(_decodeJson(articleBytes, 'article.json'));
    final attribution =
        ReadpackAttribution.parse(_decodeJson(attributionBytes, 'attribution.json'));

    // Integrity layer (contracts/README.md layers integrity before
    // semantics): declared file size and hash
    // (fixtures: missing-file, wrong-hash).
    for (final entry in manifest.files) {
      final file = files[entry.path]!;
      final actualSize = await file.length();
      if (actualSize != entry.size) {
        throw ContractViolation(
            entry.path, 'size mismatch: declared ${entry.size}, got $actualSize');
      }
      final actualHash = await sha256Of(file);
      if (actualHash != entry.sha256) {
        throw ContractViolation(entry.path, 'sha256 mismatch');
      }
    }

    // Semantic layer: identity consistency (fixture: article-id-mismatch).
    if (article.articleId != manifest.articleId ||
        article.revision != manifest.revision) {
      throw const ContractViolation(
          'article', 'article id/revision mismatch with manifest');
    }
    if (attribution.articleId != manifest.articleId ||
        attribution.revision != manifest.revision) {
      throw const ContractViolation(
          'attribution', 'article id/revision mismatch with manifest');
    }

    _validateEnvelope(manifest, article);
    _validateBlocks(article, manifest.audio, manifest.formatVersion);

    return ValidatedReadpack(
      manifest: manifest,
      article: article,
      attribution: attribution,
    );
  }

  static Object? _decodeJson(List<int> bytes, String path) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw ContractViolation(path, 'invalid json');
    }
  }

  /// Version and capability agreement between manifest and article
  /// (fixtures: unknown-capability, v10-with-markdown-blocks). The article
  /// parser already pins its own side (1.1 requires markdown-blocks, 1.0
  /// none), so what remains is equality plus the known-capability rule.
  static void _validateEnvelope(
      ReadpackManifest manifest, ArticleContent article) {
    if (manifest.formatVersion != article.formatVersion) {
      throw const ContractViolation(
          'article.format_version', 'manifest and article format versions disagree');
    }
    if (!_listEquals(manifest.requiredCapabilities,
            article.requiredCapabilities)) {
      throw const ContractViolation('manifest.required_capabilities',
          'manifest and article capabilities disagree');
    }
    for (final capability in manifest.requiredCapabilities) {
      if (!knownCapabilities.contains(capability)) {
        throw ContractViolation(
            'manifest.required_capabilities',
            'markdown_capability_unsupported: unknown required capability '
            '"$capability"');
      }
    }
    if (manifest.formatVersion == '1.1') {
      if (!manifest.requiredCapabilities.contains('markdown-blocks')) {
        throw const ContractViolation('manifest.required_capabilities',
            'a 1.1 package must require the markdown-blocks capability');
      }
    } else if (manifest.requiredCapabilities.isNotEmpty) {
      throw const ContractViolation('manifest.required_capabilities',
          'a v1.0 package must not declare required_capabilities');
    }
  }

  /// Per-block semantics for both versions, mirroring the PC validator.
  /// Block/sentence id uniqueness and positional orders are schema rules and
  /// already hold for any [ArticleContent] that parsed.
  static void _validateBlocks(
      ArticleContent article, ManifestAudio audio, String formatVersion) {
    final isV11 = formatVersion == '1.1';
    var narratableSentences = 0;
    var previousEndSample = 0;
    for (final block in article.blocks) {
      switch (block) {
        case ParsedTextBlock(:final sentences):
          narratableSentences += sentences.length;
          for (final s in sentences) {
            final path = 'article.blocks(${block.blockId})'
                '.sentences(${s.sentenceId})';

            // MVP publication profile: every narratable sentence has a
            // translation (fixture: missing-translation).
            final translation = s.translationZh;
            if (translation == null || translation.trim().isEmpty) {
              throw ContractViolation(path, 'missing translation');
            }
            if (!s.hasAudio) {
              throw ContractViolation(path, 'missing audio range');
            }

            // v1.1: non-empty runs concatenating to the sentence text
            // (fixture: empty-runs).
            if (isV11) {
              if (s.runs.isEmpty) {
                throw ContractViolation(path,
                    'a 1.1 sentence must carry non-empty runs');
              }
              if (s.runs.map((run) => run.text).join() != s.text) {
                throw ContractViolation(path,
                    'sentence runs must concatenate to the sentence text');
              }
            }

            final startSample = s.audioStartSample!;
            final endSample = s.audioEndSample!;
            final startMs = s.audioStartMs!;
            final endMs = s.audioEndMs!;

            // Non-empty, ordered range (fixture: invalid-audio-range).
            if (endSample <= startSample) {
              throw ContractViolation(path, 'empty sample range');
            }
            if (endMs <= startMs) {
              throw ContractViolation(path, 'empty millisecond range');
            }
            // Millisecond boundaries are a one-shot conversion of the sample
            // boundaries at the manifest rate: floor for start, ceil for end
            // (README data rules). ~/ floors positive operands, so ceil adds
            // rate-1 first.
            final rate = audio.sampleRateHz;
            if (startMs != (startSample * 1000) ~/ rate) {
              throw ContractViolation(
                  path, 'start ms is not floor(start_sample * 1000 / $rate)');
            }
            if (endMs != (endSample * 1000 + rate - 1) ~/ rate) {
              throw ContractViolation(
                  path, 'end ms is not ceil(end_sample * 1000 / $rate)');
            }
            // Monotonic, non-overlapping, within the audio duration.
            if (startSample < previousEndSample) {
              throw ContractViolation(path, 'overlapping audio range');
            }
            if (endMs > audio.durationMs) {
              throw ContractViolation(path, 'range exceeds audio duration');
            }
            previousEndSample = endSample;
          }
        case ParsedTableBlock(:final header, :final rows, :final translationById):
          // Cell ids are unique per article and rows match the header width
          // (schema layer). Here: the translation map covers exactly the
          // table's cells and no value is blank (fixture:
          // table-translation-shape).
          final expected = <String>{
            for (final cell in header) cell.cellId,
            for (final row in rows)
              for (final cell in row) cell.cellId,
          };
          if (!translationById.keys.toSet().containsAll(expected) ||
              translationById.length != expected.length) {
            throw const ContractViolation('article.blocks(table)',
                'translated cells must match the original cell identity set');
          }
          for (final value in translationById.values) {
            if (value.trim().isEmpty) {
              throw const ContractViolation('article.blocks(table)',
                  'translated table cells must not be empty');
            }
          }
        case ParsedCodeBlock():
          // No translation and no sentences is a schema rule (fixture:
          // code-with-translation); nothing to re-check here.
          break;
        case ParsedDividerBlock():
          break;
      }
    }
    // MVP publication profile: at least one narratable sentence with a
    // legal audio range (fixture: no-narration).
    if (narratableSentences == 0) {
      throw const ContractViolation(
          'article.blocks', 'the article needs at least one narratable sentence');
    }
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
