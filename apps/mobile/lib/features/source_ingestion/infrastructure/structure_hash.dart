import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../../contracts/readpack_v1/article.dart';

/// `structure_sha256` over the typed block union — a byte-exact port of PC
/// `structure.py`: canonical JSON (sorted keys, compact separators, raw
/// non-ASCII) of the block payloads, hashed with SHA-256. The payload shape
/// is what the shared fixtures freeze (contracts/source/v1).
String structureSha256Of(List<ParsedBlock> blocks) => crypto.sha256
    .convert(utf8.encode(canonicalJson(_payloadList(blocks))))
    .toString();

String canonicalJson(Object? value) {
  final out = StringBuffer();
  _writeCanonical(out, value);
  return out.toString();
}

void _writeCanonical(StringBuffer out, Object? value) {
  switch (value) {
    case null:
      out.write('null');
    case bool b:
      out.write(b ? 'true' : 'false');
    case num n:
      out.write(n);
    case String s:
      _writeJsonString(out, s);
    case List<Object?> list:
      out.write('[');
      for (var i = 0; i < list.length; i++) {
        if (i > 0) out.write(',');
        _writeCanonical(out, list[i]);
      }
      out.write(']');
    case Map<String, Object?> map:
      final keys = map.keys.toList()..sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        _writeJsonString(out, keys[i]);
        out.write(':');
        _writeCanonical(out, map[keys[i]]);
      }
      out.write('}');
  }
}

/// Python json.dumps-compatible escaping (ensure_ascii=False): the short
/// escapes for \b \t \n \f \r " \ and \uXXXX for the remaining controls.
void _writeJsonString(StringBuffer out, String s) {
  out.write('"');
  for (final rune in s.runes) {
    switch (rune) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x09:
        out.write(r'\t');
      case 0x0A:
        out.write(r'\n');
      case 0x0C:
        out.write(r'\f');
      case 0x0D:
        out.write(r'\r');
      default:
        if (rune < 0x20) {
          out.write(r'\u');
          out.write(rune.toRadixString(16).padLeft(4, '0'));
        } else {
          out.writeCharCode(rune);
        }
    }
  }
  out.write('"');
}

List<Object?> _payloadList(List<ParsedBlock> blocks) => [
  for (final block in blocks) blockPayload(block),
];

/// The fixture-projection payload of one block (shared corpus equality).
Map<String, Object?> blockPayload(ParsedBlock block) => _blockPayload(block);

Map<String, Object?> _blockPayload(ParsedBlock block) {
  final payload = <String, Object?>{
    'block_id': block.blockId,
    'kind': _kindOf(block),
    'order': block.order,
  };
  switch (block) {
    case ParsedTextBlock b:
      payload['style'] = b.kind.wire;
      if (b.level != null) payload['heading_level'] = b.level;
      if (b.listKind != null) {
        payload['list_kind'] = b.listKind!.name;
        payload['list_depth'] = b.listDepth;
      }
      if (b.listOrdinal != null) payload['list_ordinal'] = b.listOrdinal;
      if (b.kind == ArticleTextKind.quote) {
        payload['quote_depth'] = b.quoteDepth;
      }
      payload['sentences'] = [
        for (final sentence in b.sentences)
          {
            'sentence_id': sentence.sentenceId,
            'order': sentence.order,
            'text': sentence.text,
            'runs': [for (final run in sentence.runs) _runPayload(run)],
          },
      ];
    case ParsedTableBlock b:
      payload['alignments'] = [for (final a in b.alignments) a.wire];
      payload['header'] = [for (final cell in b.header) _cellPayload(cell)];
      payload['rows'] = [
        for (final row in b.rows) [for (final cell in row) _cellPayload(cell)],
      ];
    case ParsedCodeBlock b:
      payload['language'] = b.language;
      payload['code'] = b.code;
    case ParsedDividerBlock():
      break;
  }
  return payload;
}

Map<String, Object?> _cellPayload(ParsedTableCell cell) => {
  'cell_id': cell.cellId,
  'text': cell.text,
  'runs': [for (final run in cell.runs) _runPayload(run)],
};

Map<String, Object?> _runPayload(ArticleRun run) => {
  'kind': run.kind.wire,
  'text': run.text,
  if (run.href != null) 'href': run.href,
};

String _kindOf(ParsedBlock block) => switch (block) {
  ParsedTextBlock b => b.kind.wire,
  ParsedTableBlock() => 'table',
  ParsedCodeBlock() => 'code',
  ParsedDividerBlock() => 'divider',
};
