import 'dart:io';

import '../domain/dictionary_models.dart';
import '../infrastructure/dictionary_dao.dart';
import '../infrastructure/dictionary_database.dart';

/// Offline dictionary use cases (MOB-DIC-001…004).
///
/// The dictionary is an independent, versioned resource: when absent, every
/// other article feature keeps working and lookup reports [DictionaryResult]
/// via the [DictionaryUnavailable] state instead.
class DictionaryService {
  DictionaryService({required DictionaryManifestDao manifestDao})
      : _manifestDao = manifestDao;

  final DictionaryManifestDao _manifestDao;
  DictionaryDatabase? _openDb;
  String? _openPath;

  /// Currently installed resource, or null (screen 10B state B).
  DictionaryResource? currentResource() => _manifestDao.current();

  bool get available {
    final resource = currentResource();
    return resource != null && File(resource.path).existsSync();
  }

  DictionaryDatabase? _db() {
    final resource = currentResource();
    if (resource == null || !File(resource.path).existsSync()) return null;
    if (_openDb != null && _openPath == resource.path) return _openDb;
    _openDb?.close();
    _openDb = DictionaryDatabase.openReadOnly(resource.path);
    _openPath = resource.path;
    return _openDb;
  }

  /// Cleans a selection before lookup: trims whitespace and leading/trailing
  /// punctuation. Sentence content itself is never rewritten (MOB-DIC-002).
  /// (Unicode NFC is already guaranteed by the PC normalization pipeline.)
  static final _edgeNoise = RegExp(
      r"^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$",
      unicode: true);

  static String normalizeSelection(String raw) {
    return raw.replaceAll(_edgeNoise, '').trim();
  }

  /// Lookup with the design §8.5 order: exact phrase → normalized form →
  /// word-form table → lemma candidates. Returns an empty result (never a
  /// fabricated gloss) when nothing matches.
  DictionaryResult? lookup(String rawSelection) {
    final db = _db();
    if (db == null) return null; // dictionary not installed

    final surface = normalizeSelection(rawSelection);
    if (surface.isEmpty) {
      return DictionaryResult(surface: rawSelection, normalized: '');
    }
    final normalized = surface.toLowerCase();

    var senses = db.exact(surface);
    String? lemma;
    if (senses.isEmpty && normalized != surface) {
      senses = db.exact(normalized);
    }
    if (senses.isEmpty) {
      final lemmas = {
        ...db.lemmasFor(surface),
        if (normalized != surface) ...db.lemmasFor(normalized),
      };
      for (final candidate in lemmas) {
        final found = db.exact(candidate);
        if (found.isNotEmpty) {
          lemma = candidate;
          senses = found;
          break;
        }
      }
    }
    return DictionaryResult(
      surface: surface,
      normalized: normalized,
      lemma: lemma,
      senses: senses,
    );
  }

  void dispose() {
    _openDb?.close();
    _openDb = null;
  }
}
