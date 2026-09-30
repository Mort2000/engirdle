import 'dart:convert';

import '../../../../contracts/readpack_v1/article.dart';
import '../../../../contracts/readpack_v1/manifest.dart';
import '../../../../contracts/readpack_v2/derivatives_v2.dart'
    show NarrationRange;

/// The library's install seam for packaged translation rows: the library
/// mints the translation set id inside its install transaction and hands
/// both to the translation-owner adapter (wired to the translation DAO in
/// the composition roots), keeping table ownership intact while the install
/// stays one atomic unit (design §7.2/§11.1).
typedef InstallPackagedTranslation =
    void Function(
      ValidatedArticleImport install, {
      required String translationSetId,
    });

/// The unified install input every ingress adapter produces (lightweight
/// readpack design §5.7/§7.2): a validated, fully-moved artifact whose base
/// and optional packaged derivatives install in one transaction. The library
/// owns this seam — importers map their contract models onto it.
class ValidatedArticleImport {
  const ValidatedArticleImport({
    required this.articleId,
    required this.revision,
    required this.artifactRevision,
    required this.title,
    required this.source,
    required this.origin,
    required this.formatVersion,
    required this.sourceSha256,
    required this.structureSha256,
    required this.blocks,
    required this.manifestJson,
    required this.attributionJson,
    required this.artifactSizeBytes,
    required this.artifactSha256,
    this.packageId,
    this.sourceSyntax,
    this.normalizedSha256,
    this.parserVersion,
    this.segmenterVersion,
    this.translation,
    this.narration,
  });

  final String articleId;
  final int revision;
  final int artifactRevision;
  final String title;
  final ArticleSource source;

  /// `catalog` (LAN-downloaded readpack), `paste`, or `document`
  /// (SAF-picked package or raw file).
  final String origin;

  /// Wire family of the artifact: `1.0`/`1.1`/`2.0` for readpacks, `local-1`
  /// for raw-source installs (the on-disk layout raw.txt/canonical.txt).
  final String formatVersion;

  /// Raw-source identity (both NULL for catalog installs): source_syntax is
  /// `plain_text` or `markdown`; normalized_sha256 drives content-duplicate
  /// detection (§6.3).
  final String? sourceSyntax;
  final String? normalizedSha256;

  final String sourceSha256;
  final String structureSha256;
  final String? parserVersion;
  final String? segmenterVersion;

  final List<ParsedBlock> blocks;

  /// Raw envelope JSON for the attribution page. Raw installs synthesize a
  /// small manifest-like document (no fake readpack fields).
  final String manifestJson;
  final String attributionJson;

  /// Artifact-level identity recorded on article_artifacts: the package file
  /// (readpacks) or the raw source snapshot (raw installs).
  final int artifactSizeBytes;
  final String artifactSha256;
  final String? packageId;

  final PackagedTranslationImport? translation;
  final NarrationImport? narration;

  /// Maps a fully validated v1 package onto the unified install input.
  /// [origin] defaults to `catalog` (the LAN path); SAF-picked packages pass
  /// `document`. The artifact identity defaults to the legacy audio-entry
  /// recording; callers holding the actual ZIP can override it.
  factory ValidatedArticleImport.fromV1({
    required ArticleContent content,
    required ReadpackManifest manifest,
    required String manifestJson,
    required String attributionJson,
    String origin = 'catalog',
    int? artifactSizeBytes,
    String? artifactSha256,
  }) {
    final audio = manifest.fileFor('audio/article.m4a');
    return ValidatedArticleImport(
      articleId: content.articleId,
      revision: content.revision,
      artifactRevision: manifest.artifactRevision,
      title: content.title,
      source: content.source,
      origin: origin,
      formatVersion: manifest.formatVersion,
      sourceSha256: content.sourceSha256,
      structureSha256: content.structureSha256,
      segmenterVersion: manifest.pipeline.segmenter,
      blocks: content.blocks,
      manifestJson: manifestJson,
      attributionJson: attributionJson,
      artifactSizeBytes: artifactSizeBytes ?? audio.size,
      artifactSha256: artifactSha256 ?? audio.sha256,
      packageId: manifest.packageId,
      translation: PackagedTranslationImport.fromV1Content(content, manifest),
      narration: NarrationImport.fromV1Content(content, manifest),
    );
  }
}

/// A complete packaged translation set installed with the base and activated.
class PackagedTranslationImport {
  const PackagedTranslationImport({
    required this.locale,
    required this.pipelineJson,
    required this.sentences,
    required this.cells,
  });

  final String locale;
  final String pipelineJson;
  final List<(String sentenceId, String text)> sentences;
  final List<(String blockId, String cellId, String text)> cells;

  static PackagedTranslationImport? fromV1Content(
    ArticleContent content,
    ReadpackManifest manifest,
  ) {
    final sentences = [
      for (final block in content.blocks)
        if (block is ParsedTextBlock)
          for (final sentence in block.sentences)
            if (sentence.translationZh != null)
              (sentence.sentenceId, sentence.translationZh!),
    ];
    final cells = [
      for (final block in content.blocks)
        if (block is ParsedTableBlock)
          for (final entry in block.translationById.entries)
            (block.blockId, entry.key, entry.value),
    ];
    if (sentences.isEmpty && cells.isEmpty) return null;
    return PackagedTranslationImport(
      locale: 'zh-Hans',
      pipelineJson: jsonEncode({
        'provider': manifest.pipeline.translationProvider,
        'model': manifest.pipeline.translationModel,
        'prompt': manifest.pipeline.translationPrompt,
        'thinking': manifest.pipeline.translationThinking,
        'reasoning_effort': manifest.pipeline.translationReasoningEffort,
      }),
      sentences: sentences,
      cells: cells,
    );
  }
}

/// A complete narration asset installed with the base (readpack v1 audio or
/// the v2 narration derivative). Mobile-generated content never has one.
class NarrationImport {
  const NarrationImport({
    required this.audioPath,
    required this.codec,
    required this.sampleRateHz,
    required this.channels,
    required this.durationMs,
    required this.ranges,
  });

  final String audioPath;
  final String codec;
  final int sampleRateHz;
  final int channels;
  final int durationMs;
  final List<NarrationRange> ranges;

  static NarrationImport? fromV1Content(
    ArticleContent content,
    ReadpackManifest manifest,
  ) {
    final ranges = [
      for (final block in content.blocks)
        if (block is ParsedTextBlock)
          for (final sentence in block.sentences)
            if (sentence.hasAudio)
              NarrationRange(
                sentenceId: sentence.sentenceId,
                startMs: sentence.audioStartMs!,
                endMs: sentence.audioEndMs!,
                startSample: sentence.audioStartSample!,
                endSample: sentence.audioEndSample!,
              ),
    ];
    if (ranges.isEmpty) return null;
    return NarrationImport(
      audioPath: manifest.audio.path,
      codec: manifest.audio.codec,
      sampleRateHz: manifest.audio.sampleRateHz,
      channels: manifest.audio.channels,
      durationMs: manifest.audio.durationMs,
      ranges: ranges,
    );
  }
}
