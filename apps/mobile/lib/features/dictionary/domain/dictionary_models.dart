/// One candidate sense from the offline dictionary.
class DictionarySense {
  const DictionarySense({
    required this.senseId,
    required this.headword,
    required this.partOfSpeech,
    required this.glossEn,
    this.glossZh,
    required this.sourceName,
  });

  /// Namespace-qualified sense id (e.g. `wk.en/mend#v.1`); stored but never
  /// shown in the user flow (design 假设②).
  final String senseId;
  final String headword;
  final String partOfSpeech;
  final String glossEn;
  final String? glossZh;
  final String sourceName;
}

/// Result of a lookup (MOB-DIC-002).
class DictionaryResult {
  const DictionaryResult({
    required this.surface,
    required this.normalized,
    this.lemma,
    this.senses = const [],
  });

  /// The user's selection after cleanup (what the UI shows as the headword).
  final String surface;

  /// Normalized (trimmed, case-folded) form actually queried.
  final String normalized;

  /// Matched lemma when the surface is an inflected form (「原形」).
  final String? lemma;

  /// Candidate senses ordered by part of speech and source.
  final List<DictionarySense> senses;

  bool get found => senses.isNotEmpty;
}

/// Versioned dictionary resource metadata (MOB-DIC-004).
class DictionaryResource {
  const DictionaryResource({
    required this.dictionaryId,
    required this.revision,
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    required this.displayName,
    required this.sources,
    required this.modifications,
  });

  final String dictionaryId;
  final int revision;
  final String path;
  final int sizeBytes;
  final String sha256;
  final String displayName;

  /// e.g. `Wiktionary（CC BY-SA 3.0）`.
  final List<String> sources;
  final String? modifications;
}
