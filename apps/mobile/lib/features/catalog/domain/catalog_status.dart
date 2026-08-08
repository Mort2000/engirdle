import '../../../contracts/catalog_v1/catalog.dart';
import '../../../shared_kernel/content_identity.dart';

/// How one catalog package relates to the local install (MOB-CAT-001).
enum CatalogEntryStatus { notInstalled, upToDate, updateAvailable }

/// A catalog entry merged with local install state.
class CatalogEntry {
  const CatalogEntry({required this.package, required this.status});

  final CatalogPackage package;
  final CatalogEntryStatus status;
}

/// Compares remote packages with local installs. A higher `revision` or
/// `artifact_revision` both count as "有更新".
CatalogEntryStatus statusOf(CatalogPackage package, ArticleRef? installed) {
  final local = installed;
  if (local == null || local.articleId != package.articleId) {
    return CatalogEntryStatus.notInstalled;
  }
  return local.isOlderThan(package.ref)
      ? CatalogEntryStatus.updateAvailable
      : CatalogEntryStatus.upToDate;
}
