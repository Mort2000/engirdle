import '../../../../contracts/readpack_v1/article.dart';

/// The two raw-source syntaxes (design §6.1). Plain text never interprets
/// markdown; markdown runs the frozen-subset parser.
enum SourceSyntax {
  plainText,
  markdown;

  String get wire => switch (this) {
        plainText => 'plain_text',
        markdown => 'markdown',
      };

  static SourceSyntax? fromWire(String wire) => switch (wire) {
        'plain_text' => plainText,
        'markdown' => markdown,
        _ => null,
      };

  static SourceSyntax fromFileName(String fileName) => switch (fileName) {
        _ when fileName.toLowerCase().endsWith('.md') => markdown,
        _ when fileName.toLowerCase().endsWith('.markdown') => markdown,
        _ => plainText,
      };
}

/// One structuring attempt over a frozen raw source: the immutable base
/// content before the user confirms import metadata (design §6.3).
class RawSourceCandidate {
  const RawSourceCandidate({
    required this.syntax,
    required this.canonical,
    required this.blocks,
    required this.warnings,
    required this.sourceSha256,
    required this.normalizedSha256,
    required this.structureSha256,
    required this.suggestedTitle,
    required this.counts,
    required this.canTranslate,
  });

  final SourceSyntax syntax;

  /// BOM-stripped, LF-unified source text — the only normalization allowed
  /// before structuring (the mobile path also strips a leading BOM, which PC
  /// never sees; contracts/source/v1 §对齐规则).
  final String canonical;
  final List<ParsedBlock> blocks;
  final List<RawSourceWarning> warnings;

  final String sourceSha256;
  final String normalizedSha256;
  final String structureSha256;

  /// Suggested article title (first heading, else first sentence); the
  /// confirmation page always lets the user override it.
  final String suggestedTitle;

  final RawSourceCounts counts;

  /// Whether a translation derivative could cover this base (v2 README:
  /// at least one text sentence or one non-empty table).
  final bool canTranslate;
}

class RawSourceWarning {
  const RawSourceWarning({required this.code, this.blockIndex});

  final String code;
  final int? blockIndex;
}

class RawSourceCounts {
  const RawSourceCounts({
    required this.blocks,
    required this.sentences,
    required this.tables,
    required this.codeBlocks,
  });

  final int blocks;
  final int sentences;
  final int tables;
  final int codeBlocks;
}
