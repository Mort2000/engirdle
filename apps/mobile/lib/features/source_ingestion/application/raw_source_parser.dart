import 'dart:convert';
import 'dart:typed_data';

import '../../../contracts/readpack_v1/article.dart';
import '../domain/raw_source.dart';
import '../domain/source_parse_error.dart';
import '../infrastructure/markdown/markdown_limits.dart';
import '../infrastructure/markdown_parser.dart';
import '../infrastructure/plain_text_structurer.dart';
import '../infrastructure/structure_hash.dart';

/// The unified raw-source structuring entry (design §6.1/§6.3): paste and
/// file inputs both freeze to canonical text first, then structure through
/// the syntax-appropriate parser. Outputs everything the confirmation page
/// and the install step need.
class RawSourceParser {
  const RawSourceParser({this.limits = defaultMarkdownLimits});

  final MarkdownLimits limits;

  /// UTF-8 candidate ceiling (design §6.1): no truncation, no partial import.
  static const maxSourceBytes = 8 * 1024 * 1024;

  /// The paste adapter: the editor hands over the exact confirmed string.
  RawSourceCandidate parsePaste({
    required String text,
    required SourceSyntax syntax,
  }) {
    final bytes = utf8.encode(text);
    return _structure(
      rawBytes: bytes,
      canonicalText: _canonicalize(text),
      syntax: syntax,
    );
  }

  /// The document adapter: `.txt`/`.md`/`.markdown` file bytes picked through
  /// SAF. Anything else is an actionable error, never a guess.
  RawSourceCandidate parseFile({
    required Uint8List bytes,
    required String fileName,
  }) {
    if (bytes.length > maxSourceBytes) {
      throw const SourceParseException('source_too_large');
    }
    final syntax = SourceSyntax.fromFileName(fileName);
    final decoded = _decodeUtf8(bytes);
    return _structure(
      rawBytes: bytes,
      canonicalText: _canonicalize(decoded),
      syntax: syntax,
    );
  }

  static String _decodeUtf8(Uint8List bytes) {
    // BOM-stripping decode; a bare U+FEFF is a BOM only at the very start.
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const SourceParseException('invalid_utf8');
    }
  }

  static String _canonicalize(String text) {
    var canonical = text;
    if (canonical.startsWith('﻿')) {
      canonical = canonical.substring(1);
    }
    return canonical.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  RawSourceCandidate _structure({
    required List<int> rawBytes,
    required String canonicalText,
    required SourceSyntax syntax,
  }) {
    // source_sha256 hashes the original bytes (file) or the confirmed
    // editor string (paste); normalized_sha256 hashes the canonical text.
    final sourceSha = _hexSha256(rawBytes);

    final List<ParsedBlock> blocks;
    final warnings = <RawSourceWarning>[];
    switch (syntax) {
      case SourceSyntax.markdown:
        final parsed = parseMarkdownSource(canonicalText, limits: limits);
        blocks = parsed.blocks;
        warnings.addAll([
          for (final w in parsed.warnings)
            RawSourceWarning(code: w.code, blockIndex: w.blockIndex),
        ]);
      case SourceSyntax.plainText:
        blocks = const PlainTextStructurer().structure(canonicalText);
    }

    final normalizedSha = _hexSha256(utf8.encode(canonicalText));
    final structureSha = structureSha256Of(blocks);
    return RawSourceCandidate(
      syntax: syntax,
      canonical: canonicalText,
      blocks: blocks,
      warnings: warnings,
      sourceSha256: sourceSha,
      normalizedSha256: normalizedSha,
      structureSha256: structureSha,
      suggestedTitle: _suggestTitle(blocks),
      counts: _count(blocks),
      canTranslate: _canTranslate(blocks),
    );
  }

  static String _hexSha256(List<int> bytes) => sha256OfBytes(bytes);

  static String _suggestTitle(List<ParsedBlock> blocks) {
    for (final block in blocks) {
      if (block is ParsedTextBlock &&
          block.kind == ArticleTextKind.heading &&
          block.sentences.isNotEmpty) {
        return _clip(block.sentences.first.text);
      }
    }
    for (final block in blocks) {
      if (block is ParsedTextBlock && block.sentences.isNotEmpty) {
        return _clip(block.sentences.first.text);
      }
    }
    for (final block in blocks) {
      if (block is ParsedTableBlock && block.header.isNotEmpty) {
        return _clip(block.header.first.text);
      }
    }
    return '';
  }

  static String _clip(String text) {
    const max = 80;
    if (text.length <= max) return text;
    return '${text.substring(0, max)}…';
  }

  static RawSourceCounts _count(List<ParsedBlock> blocks) {
    var sentences = 0;
    var tables = 0;
    var codeBlocks = 0;
    for (final block in blocks) {
      switch (block) {
        case ParsedTextBlock b:
          sentences += b.sentences.length;
        case ParsedTableBlock():
          tables += 1;
        case ParsedCodeBlock():
          codeBlocks += 1;
        case ParsedDividerBlock():
          break;
      }
    }
    return RawSourceCounts(
      blocks: blocks.length,
      sentences: sentences,
      tables: tables,
      codeBlocks: codeBlocks,
    );
  }

  static bool _canTranslate(List<ParsedBlock> blocks) {
    for (final block in blocks) {
      if (block is ParsedTextBlock && block.sentences.isNotEmpty) return true;
      if (block is ParsedTableBlock && block.header.isNotEmpty) return true;
    }
    return false;
  }
}
