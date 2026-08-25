import 'dart:convert';

import '../domain/translation_errors.dart';
import 'protected_tokens.dart';
import 'translation_plan.dart';
import 'translation_protocol.dart';

/// Validated, restored unit translation produced by [validateUnitResponse].
/// Wire texts still carried placeholders; stored texts must not.
sealed class UnitTranslation {
  const UnitTranslation({required this.blockId});

  final String blockId;
}

class SentenceUnitTranslation extends UnitTranslation {
  const SentenceUnitTranslation({
    required super.blockId,
    required this.translations,
  });

  /// (sentenceId, restored zh-Hans text), in request order.
  final List<({String sentenceId, String text})> translations;
}

class TableUnitTranslation extends UnitTranslation {
  const TableUnitTranslation({required super.blockId, required this.cells});

  /// (cellId, restored zh-Hans text) in wire order: header, then rows.
  final List<({String cellId, String text})> cells;
}

/// Parses and validates one raw assistant reply against the unit it answers
/// (protocol.json `response_rules`): BOM/one-fence stripping, strict shape,
/// identity/position checks, slot-aware placeholder verification, then a
/// single-pass restoration and the shared length cap. Anything else is a
/// [TranslationProtocolError] (transiently malformed replies share the
/// bounded retry budget, as on PC).
UnitTranslation validateUnitResponse({
  required String content,
  required TranslationPlanUnit unit,
}) {
  switch (unit) {
    case SentenceBatchPlanUnit():
      return _validateSentences(content, unit);
    case TablePlanUnit():
      return _validateTable(content, unit);
  }
}

SentenceUnitTranslation _validateSentences(
  String content,
  SentenceBatchPlanUnit unit,
) {
  final decoded = _decodeOrThrow(content, what: 'a JSON array of strings');
  if (decoded is! List) {
    throw const TranslationProtocolError(
      'sentence reply is not a JSON array',
    );
  }
  final items = <String>[];
  for (final item in decoded) {
    if (item is! String) {
      throw const TranslationProtocolError(
        'sentence reply contains a non-string item',
      );
    }
    items.add(item);
  }
  if (items.length != unit.sentences.length) {
    throw TranslationProtocolError(
      'model returned ${items.length} translations for unit ${unit.blockId} '
      'which has ${unit.sentences.length} sentences',
    );
  }
  for (final item in items) {
    if (item.trim().isEmpty) {
      throw const TranslationProtocolError(
        'every translation must be a non-empty string',
      );
    }
  }
  final map = unitProtectedMap(unit);
  verifyProtectedTokens(map, items);
  return SentenceUnitTranslation(
    blockId: unit.blockId,
    translations: [
      for (var i = 0; i < items.length; i++)
        (
          sentenceId: unit.sentences[i].sentenceId,
          text: _capped(map.restore(items[i])),
        ),
    ],
  );
}

TableUnitTranslation _validateTable(String content, TablePlanUnit unit) {
  final decoded = _decodeOrThrow(content, what: 'a JSON table object');
  if (decoded is! Map<String, Object?>) {
    throw const TranslationProtocolError('table reply is not a JSON object');
  }
  final blockId = _stringField(decoded, 'block_id');
  final columns = _intField(decoded, 'columns');
  final alignments = <String>[];
  final rawAlignments = decoded['alignments'];
  if (rawAlignments is List) {
    for (final value in rawAlignments) {
      if (value is! String) {
        throw const TranslationProtocolError(
          'table alignments contains a non-string',
        );
      }
      alignments.add(value);
    }
  } else {
    throw const TranslationProtocolError('table reply has no alignments array');
  }
  final header = _cellList(decoded['header'], 'header');
  final rows = <List<_WireCell>>[];
  final rawRows = decoded['rows'];
  if (rawRows is List) {
    for (final rawRow in rawRows) {
      rows.add(_cellList(rawRow, 'rows'));
    }
  } else {
    throw const TranslationProtocolError('table reply has no rows array');
  }
  if (columns <= 0 ||
      alignments.length != columns ||
      header.length != columns) {
    throw const TranslationProtocolError('table reply shape is inconsistent');
  }
  for (final row in rows) {
    if (row.length != columns) {
      throw const TranslationProtocolError(
        'every table row must have exactly one cell per column',
      );
    }
  }
  for (final cell in [...header, for (final row in rows) ...row]) {
    if (cell.text.trim().isEmpty || cell.cellId.trim().isEmpty) {
      throw const TranslationProtocolError(
        'every translated cell must be non-empty and carry its cell_id',
      );
    }
  }
  // The reply must be the SAME table, position by position — a set comparison
  // is not enough: swapped IDs would bind translations to the wrong cells.
  final expectedHeaderIds = [for (final c in unit.header) c.cellId];
  final actualHeaderIds = [for (final c in header) c.cellId];
  final expectedRowIds = [
    for (final row in unit.rows) [for (final c in row) c.cellId],
  ];
  final actualRowIds = [
    for (final row in rows) [for (final c in row) c.cellId],
  ];
  final allIds = [...actualHeaderIds, for (final row in actualRowIds) ...row];
  if (blockId != unit.blockId ||
      columns != unit.columns ||
      !_stringListsEqual(alignments, unit.alignments) ||
      !_stringListsEqual(actualHeaderIds, expectedHeaderIds) ||
      !_idGridsEqual(actualRowIds, expectedRowIds) ||
      allIds.toSet().length !=
          expectedHeaderIds.length +
              expectedRowIds.fold<int>(0, (sum, row) => sum + row.length)) {
    throw TranslationProtocolError(
      'model changed the structure or cell positions of table ${unit.blockId}',
    );
  }
  final cellsInOrder = [...header, for (final row in rows) ...row];
  final map = unitProtectedMap(unit);
  verifyProtectedTokens(
    map,
    [for (final cell in cellsInOrder) cell.text],
  );
  return TableUnitTranslation(
    blockId: unit.blockId,
    cells: [
      for (final cell in cellsInOrder)
        (cellId: cell.cellId, text: _capped(map.restore(cell.text))),
    ],
  );
}

/// Decoded wire cell: raw text may still carry placeholders.
typedef _WireCell = ({String cellId, String text});

List<_WireCell> _cellList(Object? value, String what) {
  if (value is! List) {
    throw TranslationProtocolError('table $what is not an array');
  }
  return [
    for (final raw in value)
      switch (raw) {
        Map<String, Object?> map => (
          cellId: _stringField(map, 'cell_id'),
          text: _stringField(map, 'text'),
        ),
        _ => throw const TranslationProtocolError(
          'table cell is not an object',
        ),
      },
  ];
}

Object? _decodeOrThrow(String content, {required String what}) {
  try {
    return jsonDecode(stripResponseFences(content));
  } on FormatException {
    throw TranslationProtocolError('model reply is not $what');
  }
}

String _stringField(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) throw TranslationProtocolError('$key is not a string');
  return value;
}

int _intField(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) throw TranslationProtocolError('$key is not an integer');
  return value;
}

String _capped(String text) {
  if (text.runes.length > kMaxTranslationChars) {
    throw TranslationProtocolError(
      'translation exceeds the $kMaxTranslationChars-character limit',
    );
  }
  return text;
}

bool _stringListsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _idGridsEqual(List<List<String>> a, List<List<String>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_stringListsEqual(a[i], b[i])) return false;
  }
  return true;
}
