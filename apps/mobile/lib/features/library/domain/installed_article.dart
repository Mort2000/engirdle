import '../../../contracts/readpack_v1/article.dart';
import '../../../shared_kernel/content_identity.dart';

/// An article revision installed on this device (MOB-LIB-001). The base is
/// immutable source structure; translations and narration are separate
/// derivatives whose presence is summarized here for list rows and headers.
class InstalledArticle {
  const InstalledArticle({
    required this.articleId,
    required this.title,
    this.author,
    this.sourceDisplayName,
    this.sourceUrl,
    required this.revision,
    required this.artifactRevision,
    required this.packageId,
    required this.formatVersion,
    required this.origin,
    this.hasTranslation = false,
    this.sourceSha256,
    this.normalizedSha256,
    this.sourceSyntax,
    this.structureSha256,
    this.narration,
    required this.installedAt,
  });

  final String articleId;
  final String title;
  final String? author;
  final String? sourceDisplayName;
  final String? sourceUrl;
  final int revision;
  final int artifactRevision;
  final String? packageId;
  final String formatVersion;

  /// How the base entered the library: `catalog` (PC readpack), `paste`, or
  /// `document` (SAF-picked package or raw file).
  final String origin;

  /// An active complete translation set covers the article (list badge).
  final bool hasTranslation;

  /// SHA-256 of the raw source text the base was structured from.
  final String? sourceSha256;

  /// Raw-source duplicate identity (both NULL for catalog installs):
  /// content duplicates share normalized hash + syntax (§6.3).
  final String? normalizedSha256;
  final String? sourceSyntax;

  /// Exact structure hash the derivatives must bind to; NULL only for
  /// pre-v5 installs that never persisted it.
  final String? structureSha256;

  /// Present only when a narration asset covers this article.
  final InstalledNarrationSummary? narration;

  final DateTime installedAt;

  ArticleRef get ref => ArticleRef(
    articleId: articleId,
    revision: revision,
    artifactRevision: artifactRevision,
  );
}

/// Audio description of an installed narration asset (readpack v1 layout).
class InstalledNarrationSummary {
  const InstalledNarrationSummary({
    required this.audioPath,
    required this.codec,
    required this.sampleRateHz,
    required this.channels,
    required this.durationMs,
  });

  /// Path relative to the article artifact directory.
  final String audioPath;
  final String codec;
  final int sampleRateHz;
  final int channels;
  final int durationMs;
}

/// What the reader and player may do with an article right now: derived from
/// an active complete translation set and an installed narration asset —
/// never from forged placeholder values (lightweight-readpack design §4.2).
class ArticleCapabilities {
  const ArticleCapabilities({
    required this.hasTranslation,
    required this.hasNarration,
  });

  final bool hasTranslation;
  final bool hasNarration;
}

/// Full installed content in reading order, for the reader and player.
class InstalledContent {
  const InstalledContent({
    required this.article,
    required this.blocks,
    required this.capabilities,
    this.audioFilePath,
  });

  final InstalledArticle article;
  final List<InstalledBlock> blocks;
  final ArticleCapabilities capabilities;

  /// Absolute path of the narration audio; null when the article has no
  /// narration asset (reading-only articles never fake one).
  final String? audioFilePath;

  /// All sentences in reading order. Only text blocks bear sentences, so
  /// table/code/divider blocks can never enter the playback range list.
  List<InstalledSentence> get sentences => [
    for (final block in blocks)
      if (block is InstalledTextBlock) ...block.sentences,
  ];

  /// sentenceId to its display label, computed from reading order (opaque
  /// IDs are never parsed for display). Shared by the reader header and the
  /// playback source adapter so the bar and the media notification agree.
  Map<String, String> get sentenceLabels {
    final labels = <String, String>{};
    var paragraph = 0;
    for (final block in blocks) {
      if (block is! InstalledTextBlock) continue;
      paragraph += 1;
      final sentences = block.sentences;
      for (var s = 0; s < sentences.length; s++) {
        labels[sentences[s].sentenceId] = '第 $paragraph 段第 ${s + 1} 句';
      }
    }
    return labels;
  }

  /// Approximate English word count for the reader meta line.
  int get approximateWordCount {
    var count = 0;
    final wordPattern = RegExp(r"[A-Za-z0-9']+");
    for (final sentence in sentences) {
      count += wordPattern.allMatches(sentence.text).length;
    }
    return count;
  }
}

/// The installed block union (readpack v1.1). JSON only exists at the DAO
/// seam: installs encode typed payloads into blocks.payload_json, reads
/// decode them back. Legacy v3 rows decode as plain paragraphs.
sealed class InstalledBlock {
  const InstalledBlock({required this.blockId, required this.order});

  final String blockId;
  final int order;
}

/// paragraph / heading / list_item / quote — the sentence-bearing kinds.
class InstalledTextBlock extends InstalledBlock {
  const InstalledTextBlock({
    required super.blockId,
    required super.order,
    required this.kind,
    required this.sentences,
    this.level,
    this.listKind,
    this.listDepth = 0,
    this.listOrdinal,
    this.quoteDepth = 1,
  });

  final ArticleTextKind kind;

  /// heading only: 1-6.
  final int? level;

  /// list_item only.
  final ArticleListKind? listKind;
  final int listDepth;
  final int? listOrdinal;

  /// quote only: 1-4.
  final int quoteDepth;

  final List<InstalledSentence> sentences;
}

class InstalledTableBlock extends InstalledBlock {
  const InstalledTableBlock({
    required super.blockId,
    required super.order,
    required this.alignments,
    required this.header,
    required this.rows,
    required this.translationById,
  });

  final List<TableAlignment> alignments;
  final List<InstalledTableCell> header;
  final List<List<InstalledTableCell>> rows;

  /// cellId to translated text.
  final Map<String, String> translationById;
}

class InstalledTableCell {
  const InstalledTableCell({
    required this.cellId,
    required this.text,
    this.runs = const [],
  });

  final String cellId;
  final String text;
  final List<ArticleRun> runs;
}

class InstalledCodeBlock extends InstalledBlock {
  const InstalledCodeBlock({
    required super.blockId,
    required super.order,
    this.language,
    required this.code,
  });

  final String? language;
  final String code;
}

class InstalledDividerBlock extends InstalledBlock {
  const InstalledDividerBlock({required super.blockId, required super.order});
}

class InstalledSentence {
  const InstalledSentence({
    required this.sentenceId,
    required this.blockId,
    required this.order,
    required this.text,
    required this.runs,
    this.translationZh,
    this.audioStartMs,
    this.audioEndMs,
  });

  final String sentenceId;
  final String blockId;
  final int order;
  final String text;

  /// Inline render runs (v1.1); v1.0 rows decode as one plain run whose
  /// text is the sentence text.
  final List<ArticleRun> runs;

  final String? translationZh;
  final int? audioStartMs;
  final int? audioEndMs;

  bool get hasAudio => audioStartMs != null && audioEndMs != null;
}

/// Whole-text display modes (MOB-READ-002).
enum ReadingMode {
  enOnly,
  bilingual,
  zhOnly;

  static ReadingMode fromName(String name) => ReadingMode.values.firstWhere(
    (m) => m.name == name,
    orElse: () => ReadingMode.enOnly,
  );
}
