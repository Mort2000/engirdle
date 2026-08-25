import '../../../contracts/readpack_v1/article.dart';
import '../../library/domain/installed_article.dart';

/// The translation plan derived once from a frozen article base (design
/// §8.1): sentence batches (one per text block) and whole tables in article
/// order. Code blocks and dividers never produce units.
sealed class TranslationPlanUnit {
  const TranslationPlanUnit({required this.blockId});

  final String blockId;
}

class PlanSentence {
  const PlanSentence({required this.sentenceId, required this.runs});

  final String sentenceId;
  final List<ArticleRun> runs;
}

/// One text block's visible sentences — one wire unit, never split further.
class SentenceBatchPlanUnit extends TranslationPlanUnit {
  const SentenceBatchPlanUnit({
    required super.blockId,
    required this.sentences,
  });

  final List<PlanSentence> sentences;
}

class PlanTableCell {
  const PlanTableCell({required this.cellId, required this.runs});

  final String cellId;
  final List<ArticleRun> runs;
}

/// One whole table — exactly one wire unit, never split per cell.
class TablePlanUnit extends TranslationPlanUnit {
  const TablePlanUnit({
    required super.blockId,
    required this.alignments,
    required this.header,
    required this.rows,
  });

  /// Wire alignment names (`default`/`left`/`center`/`right`).
  final List<String> alignments;
  final List<PlanTableCell> header;
  final List<List<PlanTableCell>> rows;

  int get columns => header.length;

  /// Cells in wire order: header first, then rows flattened.
  List<PlanTableCell> get cellsInOrder => [
    ...header,
    for (final row in rows) ...row,
  ];
}

class TranslationPlan {
  const TranslationPlan({required this.units});

  final List<TranslationPlanUnit> units;

  /// An article is translatable only with at least one sentence or one
  /// non-empty table (readpack v2 §5.4: pure code/divider packages can be
  /// read but not translated).
  bool get canTranslate => units.isNotEmpty;
}

/// Derives the plan from the immutable installed blocks, in reading order.
/// Empty text blocks (no sentences) contribute nothing.
TranslationPlan buildTranslationPlan(List<InstalledBlock> blocks) {
  final units = <TranslationPlanUnit>[];
  for (final block in blocks) {
    switch (block) {
      case InstalledTextBlock():
        if (block.sentences.isEmpty) continue;
        units.add(
          SentenceBatchPlanUnit(
            blockId: block.blockId,
            sentences: [
              for (final sentence in block.sentences)
                PlanSentence(
                  sentenceId: sentence.sentenceId,
                  runs: sentence.runs,
                ),
            ],
          ),
        );
      case InstalledTableBlock():
        final header = [
          for (final cell in block.header)
            PlanTableCell(cellId: cell.cellId, runs: cell.runs),
        ];
        if (header.isEmpty) continue;
        units.add(
          TablePlanUnit(
            blockId: block.blockId,
            alignments: [
              for (final alignment in block.alignments) alignment.wire,
            ],
            header: header,
            rows: [
              for (final row in block.rows)
                [
                  for (final cell in row)
                    PlanTableCell(cellId: cell.cellId, runs: cell.runs),
                ],
            ],
          ),
        );
      case InstalledCodeBlock() || InstalledDividerBlock():
        break;
    }
  }
  return TranslationPlan(units: units);
}

/// The unit's run lists in wire order (sentences; header then row cells).
List<List<ArticleRun>> unitRunLists(TranslationPlanUnit unit) {
  switch (unit) {
    case SentenceBatchPlanUnit():
      return [for (final sentence in unit.sentences) sentence.runs];
    case TablePlanUnit():
      return [for (final cell in unit.cellsInOrder) cell.runs];
  }
}
