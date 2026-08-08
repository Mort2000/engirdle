/// Process-lifetime refcount of pinned audio artifacts (design §6.3).
///
/// The playback coordinator pins the active session's M4A path for as long as
/// it is preparing/playing/paused, so an article upgrade or delete cannot
/// remove the file the player is still reading. `library` consults the same
/// registry as a last-resort guard before cleaning up or deleting artifacts.
///
/// One playback session pins at most one file path; refcounting covers the
/// brief overlap while a new `start` supersedes the old session. The registry
/// lives only in memory: it vanishes with the process, and startup recovery
/// removes artifacts no longer referenced by the database.
class LeaseRegistry {
  final Map<String, int> _pathCounts = {};
  final Map<String, String> _pathArticle = {};

  void pin({required String articleId, required String path}) {
    _pathCounts[path] = (_pathCounts[path] ?? 0) + 1;
    _pathArticle[path] = articleId;
  }

  void unpin(String path) {
    final count = _pathCounts[path];
    if (count == null) return;
    if (count <= 1) {
      _pathCounts.remove(path);
      _pathArticle.remove(path);
    } else {
      _pathCounts[path] = count - 1;
    }
  }

  /// Exact pinned-file check.
  bool isLeased(String path) => (_pathCounts[path] ?? 0) > 0;

  /// Whether any pinned audio file lives inside [dirPath] — the upgrade-cleanup
  /// guard, which deletes whole artifact directories.
  bool isLeasedWithin(String dirPath) {
    final prefix = '$dirPath/';
    for (final path in _pathCounts.keys) {
      if (_pathCounts[path]! > 0 && (path == dirPath || path.startsWith(prefix))) {
        return true;
      }
    }
    return false;
  }

  /// Whether any pinned artifact belongs to [articleId] — the delete guard.
  /// `_pathArticle` only retains currently-leased paths (unpin removes the
  /// entry once its refcount hits zero), so membership is authoritative.
  bool isLeasedArticle(String articleId) =>
      _pathArticle.values.contains(articleId);
}
