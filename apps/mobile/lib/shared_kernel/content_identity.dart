/// Stable content identity shared across features (design §3.1).
///
/// `block_id` / `sentence_id` are opaque strings; consumers never parse
/// numbering semantics out of them. Display ordinals are computed from the
/// ordered block/sentence arrays instead.
library;

/// Identifies one immutable article revision installed on this device.
class ArticleRef {
  const ArticleRef({
    required this.articleId,
    required this.revision,
    required this.artifactRevision,
  });

  final String articleId;
  final int revision;
  final int artifactRevision;

  /// True when [other] is a newer publish of the same article
  /// (MOB-CAT-001: higher revision or artifact_revision both count).
  bool isOlderThan(ArticleRef other) {
    assert(articleId == other.articleId);
    if (revision != other.revision) return revision < other.revision;
    return artifactRevision < other.artifactRevision;
  }

  @override
  bool operator ==(Object other) =>
      other is ArticleRef &&
      other.articleId == articleId &&
      other.revision == revision &&
      other.artifactRevision == artifactRevision;

  @override
  int get hashCode => Object.hash(articleId, revision, artifactRevision);

  @override
  String toString() => '$articleId@r$revision-a$artifactRevision';
}

/// Full cross-table sentence reference (design §3.1).
class SentenceRef {
  const SentenceRef({
    required this.articleId,
    required this.revision,
    required this.sentenceId,
  });

  final String articleId;
  final int revision;
  final String sentenceId;

  @override
  bool operator ==(Object other) =>
      other is SentenceRef &&
      other.articleId == articleId &&
      other.revision == revision &&
      other.sentenceId == sentenceId;

  @override
  int get hashCode => Object.hash(articleId, revision, sentenceId);

  @override
  String toString() => '$articleId@r$revision#$sentenceId';
}
