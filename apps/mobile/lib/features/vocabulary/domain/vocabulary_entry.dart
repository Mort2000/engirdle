import '../../../shared_kernel/content_identity.dart';

/// A saved word with its immutable context snapshot (MOB-VOC-001, design §3.1).
///
/// The entry stays fully readable after the article is upgraded or deleted:
/// sentence text, translation and dictionary version are frozen at save time.
class VocabularyEntry {
  const VocabularyEntry({
    required this.vocabularyId,
    required this.surface,
    required this.normalized,
    this.lemma,
    this.partOfSpeech,
    required this.senseId,
    this.senseEn,
    this.senseZh,
    required this.sourceName,
    required this.dictionaryId,
    required this.dictionaryRevision,
    required this.ref,
    required this.sentenceText,
    this.sentenceTranslationZh,
    required this.articleTitle,
    required this.createdAt,
  });

  final String vocabularyId;
  final String surface;
  final String normalized;
  final String? lemma;
  final String? partOfSpeech;

  /// Namespace-qualified sense id; persisted, never displayed.
  final String senseId;
  final String? senseEn;
  final String? senseZh;
  final String sourceName;
  final String dictionaryId;
  final int dictionaryRevision;

  /// Full (article_id, revision, sentence_id) reference.
  final SentenceRef ref;

  /// Frozen context snapshot.
  final String sentenceText;
  final String? sentenceTranslationZh;
  final String articleTitle;
  final DateTime createdAt;
}
