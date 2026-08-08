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

  /// All sentences in reading order.
  List<InstalledSentence> get sentences =>
      [for (final block in blocks) ...block.sentences];

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

class InstalledBlock {
  const InstalledBlock({
    required this.blockId,
    required this.kind,
    required this.order,
    required this.sentences,
  });

  final String blockId;
  final String kind;
  final int order;
  final List<InstalledSentence> sentences;
}

class InstalledSentence {
  const InstalledSentence({
    required this.sentenceId,
    required this.blockId,
    required this.order,
    required this.text,
    this.translationZh,
    this.audioStartMs,
    this.audioEndMs,
  });

  final String sentenceId;
  final String blockId;
  final int order;
  final String text;
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
