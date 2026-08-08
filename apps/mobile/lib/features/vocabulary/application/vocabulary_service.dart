import '../../../shared_kernel/content_identity.dart';
import '../../../shared_kernel/id_generator.dart';
import '../../dictionary/domain/dictionary_models.dart';
import '../../library/domain/installed_article.dart';
import '../domain/vocabulary_entry.dart';
import '../infrastructure/vocabulary_dao.dart';

/// Vocabulary use cases (MOB-VOC-001/002).
///
/// Saving is one step (UX-A1): tapping「保存该义项」in the dictionary sheet is
/// itself the explicit sense selection; the snackbar offers undo, which is
/// implemented as deleting the just-inserted entry.
class VocabularyService {
  VocabularyService({required VocabularyDao dao}) : _dao = dao;

  final VocabularyDao _dao;

  List<VocabularyEntry> list() => _dao.list();

  VocabularyEntry? byId(String vocabularyId) => _dao.byId(vocabularyId);

  int countForArticle(String articleId) => _dao.countForArticle(articleId);

  /// Persists the chosen sense with both glosses and the frozen context
  /// snapshot (sentence, translation, dictionary version).
  VocabularyEntry saveSense({
    required String surface,
    required String normalized,
    required DictionarySense sense,
    String? lemma,
    required DictionaryResource resource,
    required SentenceRef ref,
    required String sentenceText,
    String? sentenceTranslationZh,
    required InstalledArticle article,
  }) {
    final entry = VocabularyEntry(
      vocabularyId: newUuid(),
      surface: surface,
      normalized: normalized,
      lemma: lemma,
      partOfSpeech: sense.partOfSpeech,
      senseId: sense.senseId,
      senseEn: sense.glossEn,
      senseZh: sense.glossZh,
      sourceName: sense.sourceName,
      dictionaryId: resource.dictionaryId,
      dictionaryRevision: resource.revision,
      ref: ref,
      sentenceText: sentenceText,
      sentenceTranslationZh: sentenceTranslationZh,
      articleTitle: article.title,
      createdAt: DateTime.now(),
    );
    _dao.insert(entry);
    return entry;
  }

  /// Undo within the snackbar lifetime == delete the just-saved entry.
  void undoSave(String vocabularyId) => _dao.delete(vocabularyId);

  void delete(String vocabularyId) => _dao.delete(vocabularyId);
}
