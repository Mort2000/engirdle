/// The frozen stage-0 resource limits, shared verbatim with the PC parser
/// and the Readpack schema (design §4.4 / contracts/source/v1).
class MarkdownLimits {
  const MarkdownLimits({
    this.maxBlocks = 10000,
    this.maxNestingDepth = 4,
    this.maxTableColumns = 32,
    this.maxTableRows = 256,
    this.maxTableCellCharacters = 4000,
    this.maxTableTotalCharacters = 200000,
    this.maxCodeBlockBytes = 512 * 1024,
    this.maxTotalCodeBytes = 2 * 1024 * 1024,
    this.maxSentenceRuns = 2048,
    this.maxBlockSentences = 10000,
    this.maxSentenceCharacters = 20000,
    this.maxLanguageCharacters = 64,
    this.maxLinkHrefCharacters = 2048,
  });

  final int maxBlocks;
  final int maxNestingDepth;
  final int maxTableColumns;
  final int maxTableRows;
  final int maxTableCellCharacters;
  final int maxTableTotalCharacters;
  final int maxCodeBlockBytes;
  final int maxTotalCodeBytes;
  final int maxSentenceRuns;
  final int maxBlockSentences;
  final int maxSentenceCharacters;
  final int maxLanguageCharacters;
  final int maxLinkHrefCharacters;
}

const defaultMarkdownLimits = MarkdownLimits();
