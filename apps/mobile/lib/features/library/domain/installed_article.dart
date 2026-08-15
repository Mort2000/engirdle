import '../../../contracts/readpack_v1/article.dart';
import '../../../shared_kernel/content_identity.dart';

/// An article revision installed on this device (MOB-LIB-001).
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
    required this.durationMs,
    required this.installedAt,
  });

  final String articleId;
  final String title;
  final String? author;
  final String? sourceDisplayName;
  final String? sourceUrl;
  final int revision;
  final int artifactRevision;
  final String packageId;
  final String formatVersion;
  final int durationMs;
  final DateTime installedAt;

  ArticleRef get ref => ArticleRef(
        articleId: articleId,
        revision: revision,
        artifactRevision: artifactRevision,
      );
}

/// Full installed content in reading order, for the reader and player.
class InstalledContent {
  const InstalledContent({
    required this.article,
    required this.blocks,
    required this.audioFilePath,
  });

  final InstalledArticle article;
  final List<InstalledBlock> blocks;
  final String audioFilePath;

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

  static ReadingMode fromName(String name) => ReadingMode.values
      .firstWhere((m) => m.name == name, orElse: () => ReadingMode.enOnly);
}
