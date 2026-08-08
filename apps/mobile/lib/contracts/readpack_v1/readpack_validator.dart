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

/// Cross-file validation of an extracted `.readpack` (design §6.4):
///
/// - all three JSON documents parse against the v1 schemas;
/// - article identity is consistent across manifest / article / attribution;
/// - every declared file exists with matching size and SHA-256;
/// - every sentence carries a translation and a legal audio range;
/// - ranges are monotonic, non-empty and within the audio duration.
class ReadpackValidator {
  const ReadpackValidator();

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

    _validateSentences(article, manifest.audio.durationMs);

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

  static void _validateSentences(ArticleContent article, int durationMs) {
    var previousEndMs = 0;
    final sentences = article.sentencesInOrder;
    for (var i = 0; i < sentences.length; i++) {
      final s = sentences[i];
      final path = 'article.sentences[$i](${s.sentenceId})';

      // MVP publication profile: every sentence has a translation
      // (fixture: missing-translation).
      if (s.translationZh == null) {
        throw ContractViolation(path, 'missing translation');
      }
      if (!s.hasAudio) {
        throw ContractViolation(path, 'missing audio range');
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
      // boundaries at 24 kHz: floor for start, ceil for end (README data
      // rules). `~/` floors positive operands, so ceil adds rate-1 first.
      if (startMs != (startSample * 1000) ~/ 24000) {
        throw ContractViolation(
            path, 'start ms is not floor(start_sample * 1000 / 24000)');
      }
      if (endMs != (endSample * 1000 + 23999) ~/ 24000) {
        throw ContractViolation(
            path, 'end ms is not ceil(end_sample * 1000 / 24000)');
      }
      // Monotonic, non-overlapping, within the audio duration.
      if (startMs < previousEndMs) {
        throw ContractViolation(path, 'overlapping audio range');
      }
      if (endMs > durationMs) {
        throw ContractViolation(path, 'range exceeds audio duration');
      }
      previousEndMs = endMs;
    }
  }
}
