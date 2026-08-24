import 'dart:convert';
import 'dart:io';

import '../../../contracts/contract_violation.dart';
import '../../../contracts/readpack_v1/readpack_validator.dart';
import '../../../contracts/readpack_v2/derivatives_v2.dart';
import '../../../contracts/readpack_v2/readpack_v2_validator.dart';
import '../../library/domain/article_install.dart';

/// Version routing for extracted `.readpack` files (design §6.5): the
/// manifest's major decides the validator; both families project onto the
/// unified [ValidatedArticleImport]. The catalog/LAN path keeps its own
/// download pipeline — this router serves the document (SAF) ingress.
class ReadpackRouter {
  const ReadpackRouter({
    this.v1Validator = const ReadpackValidator(),
    this.v2Validator = const ReadpackV2Validator(),
  });

  final ReadpackValidator v1Validator;
  final ReadpackV2Validator v2Validator;

  Future<ValidatedArticleImport> validate(
    Map<String, File> files, {
    required Future<String> Function(File file) sha256Of,
    required String origin,
    int? artifactSizeBytes,
    String? artifactSha256,
  }) async {
    final manifestFile = files['manifest.json'];
    if (manifestFile == null || !await manifestFile.exists()) {
      throw const ContractViolation('package', 'missing file "manifest.json"');
    }
    final Object? manifestJson;
    try {
      manifestJson = jsonDecode(await manifestFile.readAsString());
    } on FormatException {
      throw const ContractViolation('manifest.json', 'invalid json');
    }
    final version = manifestJson is Map<String, Object?>
        ? manifestJson['format_version']
        : null;
    if (version is! String) {
      throw const ContractViolation(
        'manifest.format_version',
        'missing or non-string format_version',
      );
    }
    if (version.startsWith('1.')) {
      final validated = await v1Validator.validate(files, sha256Of: sha256Of);
      final raw = await manifestFile.readAsString();
      final attributionJson = await files['attribution.json']!.readAsString();
      return ValidatedArticleImport.fromV1(
        content: validated.article,
        manifest: validated.manifest,
        manifestJson: raw,
        attributionJson: attributionJson,
        origin: origin,
        artifactSizeBytes: artifactSizeBytes,
        artifactSha256: artifactSha256,
      );
    }
    if (version.startsWith('2.')) {
      final validated = await v2Validator.validate(files, sha256Of: sha256Of);
      return _v2ToInstall(
        validated,
        files,
        origin,
        artifactSizeBytes,
        artifactSha256,
      );
    }
    throw ContractViolation(
      'manifest.format_version',
      'unsupported major version "$version"',
    );
  }

  static Future<ValidatedArticleImport> _v2ToInstall(
    ValidatedReadpackV2 validated,
    Map<String, File> files,
    String origin,
    int? artifactSizeBytes,
    String? artifactSha256,
  ) async {
    final manifest = validated.manifest;
    final article = validated.article;

    final PackagedTranslationImport? translation;
    if (validated.translations.isNotEmpty) {
      // First-phase consumers read exactly one zh-Hans derivative; multiple
      // locales stay a v2.x conversation.
      final t = validated.translations.first;
      translation = PackagedTranslationImport(
        locale: t.targetLocale,
        pipelineJson: t.pipelineJson,
        sentences: t.sentences,
        cells: [
          for (final (blockId, cells) in t.tables)
            for (final (cellId, text) in cells) (blockId, cellId, text),
        ],
      );
    } else {
      translation = null;
    }

    final NarrationV2? n = validated.narration;
    final NarrationImport? narration = n == null
        ? null
        : NarrationImport(
            audioPath: n.audioPath,
            codec: n.codec,
            sampleRateHz: n.sampleRateHz,
            channels: n.channels,
            durationMs: n.durationMs,
            ranges: n.ranges,
          );

    final audioEntry = manifest.files
        .where((f) => f.path == 'audio/article.m4a')
        .toList();

    return ValidatedArticleImport(
      articleId: article.articleId,
      revision: article.revision,
      artifactRevision: manifest.artifactRevision,
      title: article.title,
      source: article.source,
      origin: origin,
      formatVersion: manifest.formatVersion,
      sourceSha256: article.sourceSha256,
      normalizedSha256: article.normalizedSha256,
      sourceSyntax: manifest.parserVersion == null ? 'plain_text' : 'markdown',
      structureSha256: article.structureSha256,
      parserVersion: manifest.parserVersion,
      segmenterVersion: manifest.segmenterVersion,
      blocks: article.blocks,
      // The attribution page shows the package's own envelope bytes; the
      // router never re-serializes them.
      manifestJson: await files['manifest.json']!.readAsString(),
      attributionJson: await files['attribution.json']!.readAsString(),
      artifactSizeBytes:
          artifactSizeBytes ??
          (audioEntry.isNotEmpty ? audioEntry.first.size : 0),
      artifactSha256:
          artifactSha256 ??
          (audioEntry.isNotEmpty ? audioEntry.first.sha256 : ''),
      packageId: manifest.packageId,
      translation: translation,
      narration: narration,
    );
  }
}
