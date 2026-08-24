import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../../../contracts/readpack_v1/article.dart';
import '../domain/source_parse_error.dart';
import 'markdown/markdown_limits.dart';
import 'markdown/md_block_rules.dart' as rules;
import 'markdown/md_inline.dart';
import 'markdown/md_state.dart';
import 'markdown/md_walk.dart';

/// Result of structuring one raw source (markdown or plain text).
class ParsedRawSource {
  const ParsedRawSource({
    required this.canonical,
    required this.blocks,
    required this.warnings,
  });

  /// Line endings unified to LF; the mobile path also strips a leading BOM.
  final String canonical;
  final List<ParsedBlock> blocks;
  final List<SourceParseWarning> warnings;
}

/// The frozen parser/segmenter identifiers recorded on installs.
const kDartParserVersion = 'engirdle-gfm-dart@1';
const kDartSegmenterVersion = 'engirdle-segmenter-dart@3';

String sha256OfText(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();

/// Parses a raw markdown document exactly like PC `parse_markdown`
/// (engirdle-gfm@1), on the frozen mobile subset.
ParsedRawSource parseMarkdownSource(String raw, {MarkdownLimits? limits}) {
  limits ??= defaultMarkdownLimits;
  if (raw.trim().isEmpty) {
    throw const SourceParseException('empty_body');
  }
  final canonical = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final warnings = <SourceParseWarning>[];
  final state = MdBlockState(canonical);
  rules.tokenize(state, 0, state.lineMax);

  final childrenByToken = <BlockToken, List<InlineToken>>{};
  for (final token in state.tokens) {
    if (token.type != 'inline') continue;
    childrenByToken[token] = parseInlineTokens(token.content);
  }

  final blocks = walkTokens(
    tokens: state.tokens,
    childrenOf: (token) =>
        childrenByToken[token] ??
        (throw StateError('inline token without children')),
    limits: limits,
    warnings: warnings,
  );
  warnings.addAll(_unclosedFenceWarnings(canonical, blocks.length));
  if (blocks.isEmpty) {
    throw const SourceParseException('no_blocks');
  }
  if (blocks.length > limits.maxBlocks) {
    throw const SourceParseException('resource_limit', ' (document blocks)');
  }
  var totalCodeBytes = 0;
  for (final block in blocks) {
    if (block is ParsedCodeBlock) {
      totalCodeBytes += utf8BlockByteLength(block.code);
    }
  }
  if (totalCodeBytes > limits.maxTotalCodeBytes) {
    throw const SourceParseException('resource_limit', ' (total code bytes)');
  }
  return ParsedRawSource(
    canonical: canonical,
    blocks: blocks,
    warnings: warnings,
  );
}

int utf8BlockByteLength(String code) {
  var bytes = 0;
  for (final rune in code.runes) {
    if (rune < 0x80) {
      bytes += 1;
    } else if (rune < 0x800) {
      bytes += 2;
    } else if (rune < 0x10000) {
      bytes += 3;
    } else {
      bytes += 4;
    }
  }
  return bytes;
}

final RegExp _fenceLine = RegExp(r'^( {0,3})(`{3,}|~{3,})');

/// A markdown-it-tolerated unclosed fence swallows the rest of the document;
/// surface it as a warning exactly like PC `_unclosed_fence_warnings`.
List<SourceParseWarning> _unclosedFenceWarnings(
  String canonical,
  int blockCount,
) {
  (String, String)? openFence;
  for (final line in canonical.split('\n')) {
    final match = _fenceLine.firstMatch(line);
    if (match == null) continue;
    final marker = match.group(2)!;
    if (openFence == null) {
      openFence = (marker[0], marker);
    } else if (marker[0] == openFence.$1 &&
        marker.length >= openFence.$2.length) {
      openFence = null;
    }
  }
  if (openFence == null) return const [];
  return [
    SourceParseWarning(code: 'unclosed_code_fence', blockIndex: blockCount),
  ];
}
